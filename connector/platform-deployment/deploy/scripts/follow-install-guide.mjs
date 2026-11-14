#!/usr/bin/env node
// Reference runner for INSTALL.json: executes prerequisites, steps (run + verify) and the
// post-install checks literally, in order, comparing exit codes and output regexes.
// Human steps stop the run unless approved (--approve id,...) or skipped (--skip-human).
//   node deploy/scripts/follow-install-guide.mjs [--guide INSTALL.json] [--approve s03-approve-install]
//        [--skip-human] [--sections prereqs,steps,post] [--dry-run]
// Inputs come from the environment (each input's `env`), else its default. Output is the last
// lines of each command; the guide's commands never print secrets.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const guidePath = opt("--guide", join(dirname(fileURLToPath(import.meta.url)), "../../INSTALL.json"));
const approved = new Set((opt("--approve", "") || "").split(",").filter(Boolean));
const skipHuman = args.includes("--skip-human");
const dry = args.includes("--dry-run");
const sections = (opt("--sections", "prereqs,steps,post")).split(",");
const g = JSON.parse(readFileSync(guidePath, "utf8"));

const env = { ...process.env };
const expand = (s) => String(s).replace(/^~(?=\/|$)/, homedir()).replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, k) => env[k] ?? "");
for (const i of g.inputs) if (env[i.env] === undefined) env[i.env] = expand(i.default);
console.log(`guide ${g.name} v${g.schema_version}; inputs: ` + g.inputs.map((i) => `${i.env}=${env[i.env]}`).join(" "));

const sh = (cmd, cwd, timeoutS = 600) => {
  const r = spawnSync("bash", ["-c", cmd], { cwd: expand(cwd || "$HOME"), env, encoding: "utf8", timeout: timeoutS * 1000, maxBuffer: 64 << 20 });
  return { code: r.status ?? (r.error ? 127 : 1), out: (r.stdout || "") + (r.stderr || "") + (r.error ? String(r.error.message) : "") };
};
const match = (res, ex) => (ex.exit_code === undefined || res.code === ex.exit_code) && (!ex.output_matches || new RegExp(ex.output_matches, "m").test(res.out));
const tail = (s, n = 12) => s.trimEnd().split("\n").slice(-n).map((l) => "      | " + l).join("\n");
let failures = 0;

function runItem(kind, s, cmd, ex, cwd) {
  if (s.when) {
    const w = sh(s.when, cwd);
    if (w.code !== 0) { console.log(`SKIP ${kind} ${s.id} (when: ${s.when})`); return "skip"; }
  }
  if (s.requires_human && !approved.has(s.id)) {
    if (skipHuman) { console.log(`SKIP ${kind} ${s.id} (requires_human, not approved)`); return "skip"; }
    console.log(`STOP ${kind} ${s.id} requires a human: ${expand(s.human_prompt || s.title)}`);
    process.exit(3);
  }
  if (dry) { console.log(`DRY  ${kind} ${s.id}: ${cmd}`); return "ok"; }
  const t0 = Date.now();
  const r = sh(cmd, cwd, s.timeout_seconds);
  const ok = match(r, ex);
  console.log(`${ok ? "PASS" : "FAIL"} ${kind} ${s.id} ${s.title || s.what || ""} (exit ${r.code}, ${((Date.now() - t0) / 1000).toFixed(1)}s)\n${tail(r.out)}`);
  if (!ok) { failures++; if (s.on_failure) console.log(`      on_failure: ${s.on_failure.diagnosis.join(" / ")}\n      rollback: ${s.on_failure.rollback}`); return "fail"; }
  if (s.verify) {
    const v = sh(s.verify.run, cwd, s.timeout_seconds);
    const vok = match(v, s.verify.expect);
    console.log(`${vok ? "PASS" : "FAIL"} verify ${s.id} (exit ${v.code})\n${tail(v.out, 6)}`);
    if (!vok) { failures++; return "fail"; }
  }
  return "ok";
}

if (sections.includes("prereqs")) for (const p of g.prerequisites) {
  const r = runItem("prereq", { ...p, requires_human: false }, p.check, p.expect, "$HOME");
  if (r === "fail" && !p.optional) { console.log("prerequisite missing; stopping"); process.exit(1); }
  if (r === "fail") failures--; // optional prerequisite: informational only
}
if (sections.includes("steps")) for (const s of g.steps) {
  if (runItem("step", s, s.run, s.expect, s.cwd) === "fail") { console.log(`stopped at ${s.id}`); process.exit(1); }
}
if (sections.includes("post")) for (const c of g.post_install_verification) runItem("check", c, c.run, c.expect, c.cwd);
console.log(failures ? `FINISHED WITH ${failures} FAILURE(S)` : "FINISHED: all executed steps and checks passed");
process.exit(failures ? 1 : 0);
