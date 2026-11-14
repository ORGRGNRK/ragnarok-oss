#!/usr/bin/env node
// Mac receipts: one receipt for every command and every file write an AI makes on this Mac.
//
//   receipt.mjs zsh <actor> <session> <source> <exit> <cwd> <command>   (from receipts.zsh, already backgrounded)
//   receipt.mjs claude-hook [--actor NAME]   PostToolUse-style hook, hook JSON on stdin: Claude Code, Grok CLI,
//                                  Gemini CLI (AfterTool), Antigravity (PostToolUse, camelCase toolCall). Actor is
//                                  worked out from the payload; --actor overrides it.
//   receipt.mjs log --actor A --cmd C [--exit N] [--cwd D] [--session S] [--ref PATH] [--action X]   manual receipt
//   receipt.mjs flush | migrate | verify | tail [N]
//
// Every receipt is redacted, appended to ~/.ragnarok/receipts-spool.jsonl (0600), then the spool is
// drained IN ORDER into ygg_receipts.mac.receipts (hash-chained, append-only) on the scratch Postgres.
// DB down -> the line stays in the spool and goes with the next successful write. Fail-open: this
// program never prints on the hook paths and always exits 0 there. Contents of files are never logged.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { classify } from "./classify.mjs";

process.env.RAGNAROK_RCPT_INTERNAL = "1"; // anything we start must not be receipted (no recursion)

const HOME = os.homedir();
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const DIR = path.join(HOME, ".ragnarok");
const SPOOL = process.env.RAGNAROK_RECEIPTS_SPOOL || path.join(DIR, "receipts-spool.jsonl");
const INFLIGHT = SPOOL + ".inflight";
const LOCK = SPOOL + ".lock";
const REJECTED = path.join(DIR, "receipts-rejected.jsonl");
const LOG = path.join(DIR, "receipts.log");
const OFF = path.join(DIR, "receipts.off");
const ENV_FILE = process.env.YGG_SCRATCH_ENV || path.join(REPO, ".env");
const HOST = "macbook";
const MAX_CMD = 8000;

// ---------------------------------------------------------------- helpers
function note(msg) {
  try {
    fs.mkdirSync(DIR, { recursive: true });
    if (fs.existsSync(LOG) && fs.statSync(LOG).size > 1_000_000) {
      const old = `${LOG}.1`;
      try { fs.rmSync(old, { force: true }); fs.renameSync(LOG, old); } catch { /* keep logging if rotation races */ }
    }
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${msg}\n`, { mode: 0o600 });
    fs.chmodSync(LOG, 0o600);
  } catch { /* fail-open */ }
}
function readEnvFile() {
  const out = {};
  try {
    for (const line of fs.readFileSync(ENV_FILE, "utf8").split("\n")) {
      const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
      if (m) out[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, "$2");
    }
  } catch { /* no env file: DB writes will fail and spool */ }
  return out;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- redaction
// The core's redactor (src/core/redact.ts, built to dist/) plus shell-specific rules.
let coreRedactor = null;
async function redactor() {
  if (coreRedactor) return coreRedactor;
  const env = readEnvFile();
  const literals = Object.entries(env).filter(([k, v]) => !/PORT$|^COMPOSE_|^YGG_MCP_TAG$|_EMAIL$/.test(k) && v.length >= 8).map(([, v]) => v);
  try {
    const { createRedactor } = await import(path.join(REPO, "dist/core/redact.js"));
    coreRedactor = createRedactor(literals);
  } catch {
    // dist/ not built: same literal masking, minimal fallback
    coreRedactor = { text: (s) => literals.reduce((a, l) => a.split(l).join("***"), s) };
  }
  return coreRedactor;
}
const SECRET_NAME = "[A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASS(?:WORD|WD)?|PWD|AUTH|CRED(?:ENTIAL)?S?|COOKIE|SESSION|PRIVATE|SIGNATURE|DSN)[A-Za-z0-9_]*";
const SHELL_RULES = [
  // NAME=value env assignments / exports / flags where NAME looks secret
  [new RegExp(`\\b(${SECRET_NAME})=("[^"]*"|'[^']*'|[^\\s;&|]+)`, "gi"), "$1=***"],
  // --password x, --token=x, -p'x' style for common secret flags
  [/(--?(?:password|passwd|pass|token|api-?key|secret|auth|access-key|secret-key|client-secret|private-key)(?:[= ]))("[^"]*"|'[^']*'|[^\s;&|]+)/gi, "$1***"],
  [/(\bsshpass\s+-p\s*)(\S+)/g, "$1***"],
  // Authorization / bearer / basic headers
  [/(authorization\s*:\s*)(bearer|basic|token)?\s*[^\s'"]+/gi, "$1$2 ***"],
  [/\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 ***"],
  // curl -u user:pass
  [/(\s-u\s+|--user[= ])([^\s:'"]+):([^\s'"]+)/g, "$1$2:***"],
  // URL credentials (core does scheme://user:pass@; also catch scheme://token@host)
  [/\b([a-z][a-z0-9+.-]*:\/\/)([^\s:/@'"]{16,})@/gi, "$1***@"],
  // well-known token shapes
  [/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xai-[A-Za-z0-9]{20,}|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{30,})\b/g, "***"],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, "***"], // JWT
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)/g, "***PRIVATE KEY***"],
  // Opaque standalone credentials in command text (not prose/output): high entropy-like tokens only.
  [/(?<![A-Za-z0-9_])[A-Za-z0-9_~+/.=-]{24,}(?![A-Za-z0-9_])/g, (token) => /[A-Za-z]/.test(token) && /\d/.test(token) && /[^A-Za-z0-9]/.test(token) ? "***" : token],
];
export async function redactText(s) {
  let out = String(s ?? "");
  for (const [re, rep] of SHELL_RULES) out = out.replace(re, rep);
  out = (await redactor()).text(out);
  return out;
}

// ---------------------------------------------------------------- building receipts
// ---------------------------------------------------------------- read-back + remote host (from the retired change hook)
/** Read a written/edited file back after the tool ran (R-75). {ok, how}, or null when it can't be checked from the file
 *  alone (a pure deletion, a notebook, another AI's tool). Only ok:true makes a receipt Confirmed. */
export function verifyFile(tool, ti, file) {
  if (!["Write", "Edit", "MultiEdit"].includes(tool)) return null;
  let data;
  try { data = fs.readFileSync(file); } catch (e) { return { ok: false, how: `file not readable after the tool ran (${e.code || "error"})` }; }
  if (tool === "Write") {
    const sha = (b) => createHash("sha256").update(b).digest("hex");
    const got = sha(data);
    return got === sha(Buffer.from(ti.content ?? "", "utf8"))
      ? { ok: true, how: `file sha256 ${got.slice(0, 12)} equals the content written` }
      : { ok: false, how: `file sha256 ${got.slice(0, 12)} differs from the content written` };
  }
  const text = data.toString("utf8");
  const edits = tool === "MultiEdit" ? ti.edits || [] : [ti];
  const news = edits.map((e) => e.new_string || "");
  if (!news.length || news.some((n) => !n)) return null;
  const missing = news.filter((n) => !text.includes(n)).length;
  if (missing) return { ok: false, how: `${missing} of ${news.length} new_string(s) not found in the file` };
  for (const e of edits) {
    const old = e.old_string || "";
    if (e.replace_all && old && !(e.new_string || "").includes(old) && text.includes(old)) return { ok: false, how: "old_string still present after replace_all" };
  }
  return { ok: true, how: `${news.length} new_string(s) found in the file` };
}

// Optional address-to-label mapping; no private machine addresses are built in.
// Example: PLATFORM_RECEIPTS_REMOTE_HOSTS='{"worker.example":"worker"}'
function remoteHosts() {
  try {
    const hosts = JSON.parse(process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS || "{}");
    return hosts && typeof hosts === "object" && !Array.isArray(hosts) ? hosts : {};
  } catch { return {}; }
}
export function remoteHost(cmd) {
  const m = /^\s*(?:\S+=\S+\s+)*(ssh|scp|rsync)\b([\s\S]*)/.exec(cmd || "");
  if (!m) return null;
  for (const tok of m[2].split(/[\s'"]+/)) {
    const h = tok.split("@").pop().split(":")[0];
    const hosts = remoteHosts();
    if (Object.hasOwn(hosts, h) && typeof hosts[h] === "string") return hosts[h];
  }
  return null;
}

async function makeReceipt({ actor, session, source, tool, command, cwd, exitCode, failed, kind, action, target, verified, at, rid, extra }) {
  const red = await redactText(command);
  let c = { kind, action, target };
  if (!kind) c = classify(command, cwd);
  const isFail = c.kind === "Change" && (failed || (exitCode != null && Number(exitCode) !== 0));
  const remote = c.kind === "Change" ? remoteHost(command) : null;
  const where = c.target || target || cwd || "?";
  // over ssh with no target of its own, the path is this Mac's folder: say so instead of passing it off as the remote host's
  const ref = !remote ? `${HOST}:${where}` : where === cwd ? `${remote}:(ssh from ${HOST}:${cwd})` : `${remote}:${where}`;
  const rec = {
    rid: rid || randomUUID(), at: at || new Date().toISOString(), host: HOST,
    kind: c.kind, action: c.action, status: isFail ? "Failed" : verified?.ok ? "Confirmed" : "Observed",
    exit_code: exitCode == null || exitCode === "" || Number.isNaN(Number(exitCode)) ? null : Number(exitCode),
    actor, session: session || null, source, tool: tool || null,
    record_ref: await redactText(ref), cwd: cwd || null,
    command: red.length > MAX_CMD ? red.slice(0, MAX_CMD) + ` …[${red.length - MAX_CMD} more chars]` : red,
  };
  if (remote) rec.remote_host = remote;   // ran from this Mac, changed that machine
  if (verified) rec.verified = verified;
  return Object.assign(rec, extra || {});
}

function spool(rec) {
  fs.mkdirSync(DIR, { recursive: true });
  fs.appendFileSync(SPOOL, JSON.stringify(rec) + "\n", { mode: 0o600 });
  try { fs.chmodSync(SPOOL, 0o600); } catch { /* raced with a flush rename */ }
}

const SHELL_TOOLS = new Set(["Bash", "run_terminal_command", "Shell", "run_terminal_cmd",
  "run_shell_command" /* Gemini CLI */, "run_command" /* Antigravity */]);
const FILE_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit", "search_replace", "hashline_edit", "write", "apply_patch",
  "StrReplace", "EditNotebook", "edit_file", "write_file", "create_file",
  "replace" /* Gemini CLI */, "write_to_file", "replace_file_content", "multi_replace_file_content", "delete_file" /* Antigravity */]);

/** Claude Code (snake_case) or Grok CLI (camelCase) PostToolUse / PostToolUseFailure payload -> receipt fields. */
export function fromHookEvent(ev, env = process.env, actorOverride = null) {
  // Antigravity: {toolCall: {name, args}, conversationId, workspacePaths, error?} (camelCase, no event name)
  const agy = Boolean(ev.toolCall && typeof ev.toolCall === "object");
  // Gemini CLI: snake_case like Claude Code, but its event is called "AfterTool"
  const gemini = !agy && ev.hook_event_name === "AfterTool";
  const codex = !agy && !gemini && !env.GROK_HOOK_EVENT && Boolean(env.CODEX_HOME || env.CODEX_THREAD_ID || env.CODEX_MANAGED_BY_NPM || ev.tool_name === "apply_patch");
  const grok = !agy && !gemini && !codex && Boolean(env.GROK_HOOK_EVENT || ev.hookEventName);
  const event = ev.hook_event_name || ev.hookEventName || (agy ? "PostToolUse" : "");
  const tool = (agy ? ev.toolCall.name : ev.tool_name || ev.toolName) || "";
  const ti = (agy ? ev.toolCall.args : ev.tool_input || ev.toolInput) || {};
  const tr = ev.tool_response ?? ev.toolResponse ?? ev.tool_output ?? ev.toolOutput ?? {};
  const kindName = agy ? "Antigravity" : gemini ? "Gemini CLI" : codex ? "Codex" : grok ? "Grok CLI" : "Claude Code";
  const actor = actorOverride || kindName;
  const session = ev.session_id || ev.sessionId || ev.conversationId || env.GROK_SESSION_ID || null;
  const failed = /failure/i.test(event) || Boolean(agy && ev.error)
    || (tr && typeof tr === "object" && (tr.is_error || tr.isError || tr.interrupted || (gemini && tr.error))) || false;
  const evCwd = ev.cwd || (agy && Array.isArray(ev.workspacePaths) ? ev.workspacePaths[0] : null) || null;
  const cwd = ti.cwd || ti.working_directory || ti.Cwd || ti.dir_path || ti.directory || evCwd;
  const prefix = { "Antigravity": "antigravity", "Gemini CLI": "gemini-cli", "Codex": "codex", "Grok CLI": "grok-cli", "Claude Code": "claude" }[kindName];
  const source = `${prefix}-${/failure/i.test(event) ? "posttoolusefailure" : "posttooluse"}`;
  if (SHELL_TOOLS.has(tool)) {
    let exit = null;
    if (tr && typeof tr === "object") exit = tr.exit_code ?? tr.exitCode ?? tr.returncode ?? tr.return_code ?? tr.code ?? null;
    if (exit == null) {
      const m = /exit(?:ed with)? (?:code|status):?\s*(-?\d+)/i.exec(String(ev.error ?? "") + " " + (typeof tr === "string" ? tr : JSON.stringify(tr ?? "")));
      if (m) exit = Number(m[1]);
    }
    if (exit == null && !failed) exit = 0;
    return { actor, session, source, tool, command: ti.command || ti.CommandLine || "", cwd, exitCode: exit, failed };
  }
  if (FILE_TOOLS.has(tool)) {
    // Codex apply_patch carries the whole diff: retain only paths and operation names, never patch text.
    const patchPaths = tool === "apply_patch" ? [...String(ti.patch || ti.input || "").matchAll(/^\*\*\*\s*(?:Update|Add|Delete) File:\s*(.+)$/gm)].map((m) => m[1]) : [];
    if (tool === "apply_patch" && !patchPaths.length) return null;
    const p = ti.file_path || ti.path || ti.notebook_path || ti.target_notebook || ti.target_file || ti.filePath
      || ti.TargetFile || ti.AbsolutePath || ti.FilePath || "?";
    if (tool === "apply_patch") {
      const evCwd = ev.cwd || null;
      return { actor, session, source, tool, command: `apply_patch ${patchPaths.length} file(s) (contents not logged)`, cwd: evCwd,
        exitCode: failed ? null : 0, failed, kind: "Change", action: "Updated",
        target: patchPaths.map((x) => path.resolve(evCwd || HOME, x)).join(", ") };
    }
    const created = (tr && typeof tr === "object" && (tr.type === "create" || tr.created === true)) || tool === "create_file";
    const abs = p.startsWith("/") ? p : path.resolve(evCwd || HOME, p);
    return {
      actor, session, source, tool, command: `${tool} ${abs} (contents not logged)`, cwd: evCwd,
      exitCode: failed ? null : 0, failed, kind: "Change", action: tool === "delete_file" ? "Deleted" : created ? "Created" : "Updated", target: abs,
    };
  }
  return null;
}

// ---------------------------------------------------------------- spool -> DB
async function connect() {
  const env = readEnvFile();
  const { default: pg } = await import("pg");
  const client = new pg.Client({
    host: "127.0.0.1", port: Number(process.env.RAGNAROK_RECEIPTS_PGPORT || env.YGG_PG_PORT || 5547),
    user: "ygg_app", password: env.YGG_APP_PASSWORD, database: "ygg_receipts",
    application_name: "mac-receipts", connectionTimeoutMillis: 1500, statement_timeout: 5000,
  });
  client.on("error", () => {});
  await client.connect();
  return client;
}

function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } }
// Lock = a directory (mkdir is atomic) holding the owner's pid. A lock is only taken over when its
// owner is dead (or it is older than 2 min), and only after it has existed for 2 s.
const LOCK_PID = path.join(LOCK, "pid");
function tryLock() {
  try {
    fs.mkdirSync(LOCK, { mode: 0o700 });
    fs.writeFileSync(LOCK_PID, String(process.pid), { mode: 0o600 });
    return true;
  } catch (e) {
    if (e.code !== "EEXIST") return false;
    try {
      const age = Date.now() - fs.statSync(LOCK).mtimeMs;
      let pid = 0;
      try { pid = Number(fs.readFileSync(LOCK_PID, "utf8")); } catch { /* owner still writing its pid */ }
      if (age > 120_000 || (age > 2_000 && (!pid || !pidAlive(pid)))) {
        const stale = `${LOCK}.stale.${process.pid}`;
        fs.renameSync(LOCK, stale); // only one taker wins this rename
        fs.rmSync(stale, { recursive: true, force: true });
      }
    } catch { /* someone else took it over */ }
    return false;
  }
}
function unlock() {
  try { if (fs.readFileSync(LOCK_PID, "utf8") === String(process.pid)) fs.rmSync(LOCK, { recursive: true, force: true }); } catch { /* ignore */ }
}
const nonEmpty = (f) => { try { return fs.statSync(f).size > 0; } catch { return false; } };
const exists = (f) => { try { fs.statSync(f); return true; } catch { return false; } };

/** Drain inflight (older) then spool (newer), oldest line first. Returns {sent, held}. */
async function flushOnce() {
  let got = false;
  for (let i = 0; i < 60 && !(got = tryLock()); i++) await sleep(100);
  if (!got) return { sent: 0, held: true };
  let client = null, sent = 0;
  try {
    for (;;) {
      if (!exists(INFLIGHT)) {
        if (!nonEmpty(SPOOL)) break;
        // Never overwrite an unsent batch: link fails if INFLIGHT already exists.
        try { fs.linkSync(SPOOL, INFLIGHT); } catch (e) { if (e.code !== "EEXIST") throw e; continue; }
        fs.unlinkSync(SPOOL);
        await sleep(30); // let an appender that opened the old inode finish its single write
      }
      const ino = fs.statSync(INFLIGHT).ino;
      const lines = fs.readFileSync(INFLIGHT, "utf8").split("\n").filter((l) => l.trim());
      if (!client) client = await connect();
      for (const line of lines) {
        let rec;
        try { rec = JSON.parse(line); } catch { fs.appendFileSync(REJECTED, line + "\n", { mode: 0o600 }); continue; }
        try {
          const r = await client.query("select seq, entry_hash, inserted from mac.append($1::jsonb)", [JSON.stringify(rec)]);
          const row = r.rows[0];
          sent++;
          note(`LOGGED seq=${row.seq}${row.inserted ? "" : " (already logged)"} rid=${rec.rid} ${rec.actor} ${rec.kind}/${rec.action}/${rec.status} exit=${rec.exit_code} ${rec.record_ref}`);
        } catch (e) {
          if (e && typeof e.code === "string" && /^(22|23)/.test(e.code)) { // bad data: set aside, keep going
            fs.appendFileSync(REJECTED, JSON.stringify({ rec, reason: e.code }) + "\n", { mode: 0o600 });
            note(`REJECTED rid=${rec.rid} sqlstate=${e.code}`);
            continue;
          }
          throw e;
        }
      }
      if (fs.statSync(INFLIGHT).ino === ino) fs.unlinkSync(INFLIGHT); // only the batch we read
    }
    return { sent, held: false };
  } catch (e) {
    note(`HELD in spool (DB unavailable: ${(await redactText(e?.code || e?.message || String(e))).slice(0, 160)})`);
    return { sent, held: true };
  } finally {
    try { await client?.end(); } catch { /* ignore */ }
    unlock();
  }
}
async function flush() {
  for (let round = 0; round < 5; round++) {
    const r = await flushOnce();
    if (r.held || (!nonEmpty(SPOOL) && !nonEmpty(INFLIGHT))) return r;
  }
}

// ---------------------------------------------------------------- commands
async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}
function argMap(a) {
  const m = {};
  for (let i = 0; i < a.length; i++) if (a[i].startsWith("--")) m[a[i].slice(2)] = a[i + 1], i++;
  return m;
}

async function main() {
  const [mode, ...rest] = process.argv.slice(2);
  if ((mode === "zsh" || mode === "claude-hook") && fs.existsSync(OFF)) return;
  if (mode === "zsh") {
    const [actor, session, source, exit, cwd, ...cmd] = rest;
    const command = cmd.join(" ");
    if (!command.trim()) return;
    spool(await makeReceipt({ actor, session, source, command, cwd, exitCode: exit }));
    await flush();
  } else if (mode === "claude-hook") {
    const a = argMap(rest);
    const ev = JSON.parse(await readStdin());
    const fields = fromHookEvent(ev, process.env, a.actor || null);
    if (!fields) return;
    if (fields.kind === "Change" && !fields.failed && fields.target) {
      fields.verified = verifyFile(fields.tool, ev.tool_input || ev.toolInput || {}, fields.target) || undefined;
    }
    spool(await makeReceipt(fields));
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "flush"],
      { detached: true, stdio: "ignore", env: process.env });
    child.unref();
  } else if (mode === "log") {
    const a = argMap(rest);
    const rec = await makeReceipt({
      actor: a.actor || "manual", session: a.session, source: "log-change", command: a.cmd || "", cwd: a.cwd || process.cwd(),
      exitCode: a.exit ?? 0, failed: a.failed === "1",
      ...(a.action ? { kind: a.action === "Read" ? "Read" : "Change", action: a.action, target: a.ref } : {}),
    });
    spool(rec);
    const r = await flush();
    console.log(r.held ? `SPOOLED rid=${rec.rid} (DB unavailable; goes with the next write)` : `LOGGED rid=${rec.rid}`);
  } else if (mode === "import-change-queue") {
    // One-time: the retired change hook (scripts/ragnarok-change-hook.py) queued entries for a receiver on the remote host
    // that no longer existed. Each becomes a receipt with its original time; the rid comes from the line's hash, so
    // running this twice logs nothing twice.
    const file = rest[0] || path.join(DIR, "change-queue.jsonl");
    let n = 0;
    for (const line of fs.readFileSync(file, "utf8").split("\n").filter((l) => l.trim())) {
      const e = JSON.parse(line);
      const h = createHash("sha256").update(line).digest("hex");
      const rid = `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
      const isFile = ["Write", "Edit", "MultiEdit", "NotebookEdit"].includes(e.tool);
      const target = isFile ? String(e.target || "?").replace(/^~(?=\/)/, HOME) : e.target;
      spool(await makeReceipt({
        actor: e.actor || "Claude Code", session: e.session, source: "change-hook-queue", tool: e.tool,
        command: isFile ? `${e.tool} ${target} (contents not logged)` : e.command, cwd: e.cwd,
        exitCode: e.result === "error" ? null : 0, failed: e.result === "error",
        kind: "Change", action: e.action, target, verified: e.verified, at: new Date(e.at).toISOString(), rid,
        extra: { queued_host: e.host },
      }));
      n++;
    }
    const r = await flush();
    console.log(`${n} queued changes spooled; ${r.held ? "DB unavailable, they go with the next write" : "logged"}`);
  } else if (mode === "flush") {
    await flush();
  } else if (mode === "migrate") {
    const c = await connect();
    for (const f of fs.readdirSync(path.join(HERE, "sql")).filter((x) => x.endsWith(".sql")).sort()) {
      await c.query(fs.readFileSync(path.join(HERE, "sql", f), "utf8"));
    }
    await c.end();
    console.log("mac.receipts ready");
  } else if (mode === "verify") {
    const c = await connect();
    const r = await c.query("select * from mac.verify()");
    await c.end();
    console.log(JSON.stringify(r.rows[0]));
    process.exitCode = r.rows[0].ok ? 0 : 1;
  } else if (mode === "tail") {
    const c = await connect();
    const r = await c.query(
      "select seq, to_char(at at time zone 'America/Los_Angeles','YYYY-MM-DD HH24:MI:SS') as at_pt, actor, kind, action, status, exit_code, record_ref, left(command, 120) as command, left(entry_hash,12) as hash from mac.receipts order by seq desc limit $1",
      [Number(rest[0] || 20)]);
    await c.end();
    for (const x of r.rows.reverse()) console.log(`#${x.seq} ${x.at_pt} PT | ${x.actor} | ${x.kind}/${x.action}/${x.status} exit=${x.exit_code ?? "-"} | ${x.record_ref} | ${x.command} | ${x.hash}`);
  } else {
    console.error("usage: receipt.mjs zsh|claude-hook|log|flush|migrate|verify|tail [N]");
    process.exitCode = 2;
  }
}

const isMain = (() => { try { return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
const hookMode = ["zsh", "claude-hook", "flush"].includes(process.argv[2]);
if (isMain) main().catch(async (e) => {
  note(`ERROR ${process.argv[2]}: ${(await redactText(e?.message || String(e))).slice(0, 300)}`);
  if (!hookMode) { console.error(await redactText(e?.message || String(e))); process.exitCode = 1; }
}).finally(() => { if (hookMode) process.exitCode = 0; });
