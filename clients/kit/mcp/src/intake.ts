// Intake file store. Bytes live in one directory (INTAKE_BLOB_DIR). Postgres keeps the
// metadata and the sha256, never the bytes. The same sha256 is one file. Nothing stored
// here is executed. Registered only for the client whose schema has intake_items.
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream, statfsSync } from "node:fs";
import { link, mkdir, open, stat, unlink } from "node:fs/promises";
import { readFileSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import type pg from "pg";
import type { Scope } from "./config.js";
import { pool, scrub } from "./db.js";
import { comparable, coerce, findField, findTable, loadSchema, type Field } from "./schema.js";
import { runWrite, type Ctx, type Result, type Who } from "./tools.js";

const PHOTO = new Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]);
const KINDS = new Set(["text", "file", "photo"]);

export class IntakeError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function numEnv(name: string, fallback: number): number {
  const n = Number(process.env[name] || fallback);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}
export function maxBytes(): number { return numEnv("INTAKE_MAX_BYTES", 5 * 1024 * 1024 * 1024); }
export function minFree(): number { return numEnv("INTAKE_MIN_FREE_BYTES", 10 * 1024 * 1024 * 1024); }

function gb(n: number): string { return (n / 1073741824).toFixed(1); }
function diskMessage(avail: number, floor: number): string {
  return `Not enough free space on the Intake disk (${gb(avail)} GB free). Intake keeps at least ${gb(floor)} GB free. Nothing was stored.`;
}
function sizeMessage(n: number, max: number): string {
  return `This is ${gb(n)} GB, over the ${gb(max)} GB per-file limit. Nothing was stored.`;
}

export function requireBlobDir(): string {
  const d = process.env.INTAKE_BLOB_DIR?.trim() || "";
  if (!d) throw new IntakeError(503, "Intake file storage is not configured. Nothing was stored.");
  if (d.includes("\0") || d.split(path.sep).includes("..")) throw new IntakeError(503, "Intake file storage path is not allowed. Nothing was stored.");
  const low = d.toLowerCase();
  if (low === "/mnt/seagate" || low.startsWith("/mnt/seagate/") || low.includes("seagate")) {
    throw new IntakeError(503, "Intake will not store files on the Seagate disk. Nothing was stored.");
  }
  return d;
}

/** A file name may be stored as data. It is never used as a path. */
export function safeFilename(raw: string | null | undefined): string | null {
  if (raw == null) return null;
  const name = String(raw).trim();
  if (!name || name.length > 255) return null;
  if (name.includes("\0") || name.includes("/") || name.includes("\\")) return null;
  if (name === "." || name === "..") return null;
  return name;
}

function givenFilename(raw: string | null | undefined): string | null {
  if (raw == null || String(raw).trim() === "") return null;
  const name = safeFilename(raw);
  if (!name) throw new IntakeError(400, "That filename is not allowed. Nothing was stored.");
  return name;
}

export function inferKind(explicit: string | undefined, filename: string | null, mime: string | null, text: boolean): "text" | "file" | "photo" {
  const e = (explicit || "").trim().toLowerCase();
  if (KINDS.has(e)) return e as "text" | "file" | "photo";
  if (text) return "text";
  if ((mime || "").toLowerCase().startsWith("image/")) return "photo";
  const ext = (filename || "").toLowerCase().split(".").pop() || "";
  if (PHOTO.has(ext)) return "photo";
  return "file";
}

function normTags(raw: string | null | undefined): string | null {
  if (raw == null || String(raw).trim() === "") return null;
  const parts = String(raw).split(",").map((s) => s.trim()).filter(Boolean);
  if (!parts.length) return null;
  const joined = parts.join(",");
  if (joined.length > 2000) throw new IntakeError(400, "Tags are too long. Nothing was stored.");
  return joined;
}

function needSender(raw: string | null | undefined): string {
  const t = (raw || "").trim();
  if (!t) throw new IntakeError(400, "Say who sent this (sender). Nothing was stored.");
  if (t.length > 200) throw new IntakeError(400, "Sender name is too long. Nothing was stored.");
  return t;
}

function clip(raw: string | null | undefined, max: number, label: string): string | null {
  if (raw == null) return null;
  const t = String(raw).trim();
  if (!t) return null;
  if (t.length > max) throw new IntakeError(400, `${label} is too long. Nothing was stored.`);
  return t;
}

function asNum(n: number | bigint): number {
  const x = typeof n === "bigint" ? Number(n) : n;
  if (!Number.isFinite(x) || x < 0) throw new IntakeError(500, "Could not read free space on the Intake disk.");
  return x;
}

function space(dir: string): { free: number; used: number; total: number } {
  const s = statfsSync(dir);
  const bsize = asNum(s.bsize);
  const blocks = asNum(s.blocks);
  const bfree = asNum(s.bfree);
  const bavail = asNum(s.bavail);
  return { free: bavail * bsize, used: (blocks - bfree) * bsize, total: blocks * bsize };
}

function mountOf(dir: string): { device: string; root: string } {
  let device = "";
  let root = "";
  let best = -1;
  try {
    const abs = path.resolve(dir);
    for (const line of readFileSync("/proc/self/mountinfo", "utf8").split("\n")) {
      const parts = line.split(" ");
      const sep = parts.indexOf("-");
      if (sep < 0 || parts.length < sep + 3) continue;
      const mountpoint = parts[4] || "";
      const prefix = mountpoint.endsWith("/") ? mountpoint : mountpoint + "/";
      if (abs !== mountpoint && !abs.startsWith(prefix)) continue;
      if (mountpoint.length < best) continue;
      best = mountpoint.length;
      root = parts[3] || "";
      device = parts[sep + 2] || "";
    }
  } catch { /* the disk fields below still come from statfs */ }
  return { device, root };
}

export async function diskInfo(): Promise<Record<string, unknown>> {
  const dir = requireBlobDir();
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const s = space(dir);
  const mount = mountOf(dir);
  const host = process.env.INTAKE_BLOB_HOST?.trim() || mount.root || dir;
  return {
    path: host,
    device: mount.device,
    free_bytes: s.free,
    used_bytes: s.used,
    total_bytes: s.total,
    floor_bytes: minFree(),
    max_file_bytes: maxBytes(),
  };
}

interface Stored { sha256: string; size: number; blob_new: boolean; dest: string }

async function storeStream(source: Readable, declared?: number): Promise<Stored> {
  const dir = requireBlobDir();
  await mkdir(path.join(dir, "tmp"), { recursive: true, mode: 0o700 });
  const max = maxBytes();
  const floor = minFree();
  const avail = space(dir).free;
  if (avail < floor || (declared !== undefined && avail - declared < floor)) throw new IntakeError(507, diskMessage(avail, floor));
  if (declared !== undefined && declared > max) throw new IntakeError(413, sizeMessage(declared, max));
  if (declared === 0) throw new IntakeError(400, "There was nothing to store.");

  const tmp = path.join(dir, "tmp", randomBytes(16).toString("hex"));
  const hash = createHash("sha256");
  let size = 0;
  const limit = new Transform({
    transform(chunk, _enc, cb) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buf.length;
      if (size > max) return cb(new IntakeError(413, sizeMessage(size, max)));
      if (avail - size < floor) return cb(new IntakeError(507, diskMessage(avail, floor)));
      hash.update(buf);
      cb(null, buf);
    },
  });
  let linked = false;
  let dest = "";
  try {
    await pipeline(source, limit, createWriteStream(tmp, { flags: "wx", mode: 0o600 }));
    if (size <= 0) throw new IntakeError(400, "There was nothing to store.");
    const fh = await open(tmp, "r+");
    await fh.sync();
    await fh.close();
    const sha256 = hash.digest("hex");
    dest = path.join(dir, sha256);
    if (!/^[a-f0-9]{64}$/.test(sha256) || path.basename(dest) !== sha256) throw new Error("bad content hash");
    try {
      await link(tmp, dest);
      linked = true;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    }
    const st = await stat(dest);
    if (st.size !== size && linked) throw new Error("stored file size does not match what was sent");
    if (!linked && st.size !== size) {
      // The bytes already on disk are the one copy. The upload must be that same content.
      throw new IntakeError(409, "A different file is already stored under this content hash. Nothing new was kept.");
    }
    return { sha256, size, blob_new: linked, dest };
  } catch (e) {
    if (linked && dest) await unlink(dest).catch(() => undefined);
    throw e;
  } finally {
    await unlink(tmp).catch(() => undefined);
  }
}

function table() { return findTable(loadSchema(), "intake_items"); }

async function receiptFor(q: pg.PoolClient, id: number, action: string) {
  const r = (await q.query(
    `SELECT seq, receipt_id, hash, action FROM write_log WHERE table_name = $1 AND record_id = $2 ORDER BY seq DESC LIMIT 1`,
    ["intake_items", String(id)])).rows[0];
  if (!r || r.action !== action) throw new Error(`no ${action} receipt was produced for Intake #${id}`);
  return { seq: Number(r.seq), receipt_id: String(r.receipt_id), hash: String(r.hash) };
}

function put(t: ReturnType<typeof table>, m: Map<Field, unknown>, name: string, value: unknown) {
  const f = findField(t, name);
  m.set(f, coerce(f, value));
}

interface Meta {
  kind: "text" | "file" | "photo";
  title: string;
  body: string | null;
  filename: string | null;
  mime: string | null;
  sender: string;
  source: string | null;
  tags: string | null;
  project: string | null;
  tool: string;
  via: string;
  actor: string;
}

async function insertItem(meta: Meta, stored: Stored): Promise<Record<string, unknown>> {
  const t = table();
  const ctx: Ctx = { scope: "write", via: meta.via, client: "intake", defaultSession: "intake" };
  const who: Who = { actor: meta.actor, session: "intake" };
  const safeArgs = {
    kind: meta.kind, title: meta.title, filename: meta.filename, mime: meta.mime,
    sender: meta.sender, tags: meta.tags, project: meta.project, source_machine: meta.source,
    size: stored.size, sha256: stored.sha256, blob_new: stored.blob_new,
  };
  const result = await runWrite(ctx, who, meta.tool, safeArgs, "intake", async (q) => {
    const m = new Map<Field, unknown>();
    put(t, m, "Kind", meta.kind);
    put(t, m, "Title", meta.title);
    if (meta.body != null) put(t, m, "Body", meta.body);
    if (meta.filename) put(t, m, "Original_Filename", meta.filename);
    if (meta.mime) put(t, m, "Mime_Type", meta.mime);
    put(t, m, "Size_Bytes", stored.size);
    put(t, m, "Sha256", stored.sha256);
    put(t, m, "Sender", meta.sender);
    if (meta.source) put(t, m, "Source_Machine", meta.source);
    if (meta.tags) put(t, m, "Tags", meta.tags);
    if (meta.project) put(t, m, "Project", meta.project);
    put(t, m, "Archived", false);
    const cols = [...m.keys()].map((f) => `"${f.column}"`);
    const id = Number((await q.query(
      `INSERT INTO intake_items (${cols.join(", ")}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(", ")}) RETURNING id`,
      [...m.values()])).rows[0].id);
    const row = (await q.query(`SELECT * FROM intake_items WHERE id = $1`, [id])).rows[0] as Record<string, unknown>;
    const bad = [...m].filter(([f, v]) => comparable(f, row[f.column]) !== comparable(f, v))
      .map(([f]) => f.name);
    if (bad.length) throw new IntakeError(500, `The saved item did not match what was sent (${bad.join(", ")}). Nothing was kept.`);
    return { touched: [{ table: t, id, expect: m, receipt: await receiptFor(q, id, "INSERT") }] };
  });
  const saved = (result.data?.results as Array<{ id?: number; status?: string }> | undefined)?.[0];
  if (!result.ok && !saved?.id) {
    const msg = result.text.split("\n")[0] || "The item was not saved.";
    throw new IntakeError(400, msg.replace(/^REFUSED -- /, "").replace(/^WRITE FAILED -- nothing was changed\. /, ""));
  }
  if (!result.ok) console.error(`[intake] read-back warning id=${saved?.id} status=${saved?.status || "unknown"}`);
  const id = Number(saved?.id);
  const row = (await pool("write").query(`SELECT * FROM intake_items WHERE id = $1`, [id])).rows[0] as Record<string, unknown>;
  return { ...shape(row, true), blob_new: stored.blob_new, blob_copies: 1 };
}

function shape(row: Record<string, unknown>, fullBody: boolean): Record<string, unknown> {
  const body = row.body == null ? null : String(row.body);
  return {
    id: Number(row.id),
    kind: row.kind,
    title: row.title == null ? "" : String(row.title),
    body: fullBody ? body : null,
    preview: body ? body.slice(0, 2000) : "",
    original_filename: row.original_filename == null ? null : String(row.original_filename),
    mime: row.mime_type == null ? null : String(row.mime_type),
    size: Number(row.size_bytes),
    sha256: String(row.sha256),
    sender: row.sender == null ? "" : String(row.sender),
    source_machine: row.source_machine == null ? null : String(row.source_machine),
    tags: row.tags == null ? "" : String(row.tags),
    project: row.project == null ? null : String(row.project),
    created: row.created_at ? new Date(String(row.created_at)).toISOString() : null,
    archived: row.archived === true || row.archived === "t" || row.archived === "true",
  };
}

async function keep(meta: Meta, bytes: Readable, declared?: number): Promise<Record<string, unknown>> {
  let stored: Stored | undefined;
  let done = false;
  try {
    stored = await storeStream(bytes, declared);
    const item = await insertItem(meta, stored);
    done = true;
    console.error(`[intake] stored id=${item.id} kind=${meta.kind} bytes=${stored.size} sha256=${stored.sha256.slice(0, 12)} new=${stored.blob_new}`);
    return item;
  } finally {
    if (stored?.blob_new && !done) await unlink(stored.dest).catch(() => undefined);
  }
}

export interface IngestFields {
  kind?: string; title?: string; body?: string; filename?: string; mime?: string;
  sender?: string; source_machine?: string; tags?: string; project?: string;
  tool: string; via: string;
}

async function metaFrom(fields: IngestFields, filename: string | null, mime: string | null, text: boolean, body: string | null): Promise<Meta> {
  const sender = needSender(fields.sender);
  const kind = inferKind(fields.kind, filename, mime, text);
  if (kind === "text" && (body == null || body.trim() === "")) throw new IntakeError(400, "Text needs some words. Nothing was stored.");
  if (body != null && body.length > 200_000) throw new IntakeError(413, "That text is longer than Intake keeps in the record. Send it as a file. Nothing was stored.");
  const title = (fields.title || "").trim()
    || filename
    || (body ? body.trim().split("\n")[0].slice(0, 80) : "")
    || "Untitled";
  if (title.length > 300) throw new IntakeError(400, "Title is too long. Nothing was stored.");
  return {
    kind, title, body: body && body.length ? body : null, filename, mime,
    sender, source: clip(fields.source_machine, 200, "Source machine"),
    tags: normTags(fields.tags), project: clip(fields.project, 200, "Project"),
    tool: fields.tool, via: fields.via, actor: sender.slice(0, 80),
  };
}

export async function ingestBuffer(fields: IngestFields, buf: Buffer, filename: string | null, mime: string | null, text: boolean): Promise<Record<string, unknown>> {
  const body = text ? buf.toString("utf8") : (fields.body ?? null);
  const meta = await metaFrom(fields, filename, mime, text, text ? body : (fields.body ?? null));
  if (!text && meta.body && meta.body.length > 200_000) throw new IntakeError(413, "That caption is too long. Nothing was stored.");
  return keep(meta, Readable.from(buf), buf.length);
}

export async function searchItems(q: pg.PoolClient, a: { query?: string; kind?: string; sender?: string; tag?: string; limit?: number }): Promise<Result> {
  const out = await queryItems(q, a.query || "", a.kind || "", a.sender || "", a.tag || "", a.limit || 100);
  return { ok: true, text: out.items.length ? out.items.map((it) => `#${it.id} ${it.kind} ${it.title} sha256:${it.sha256}`).join("\n") : "No matching Intake items.", data: out };
}

async function queryItems(q: pg.Pool | pg.PoolClient, query: string, kind: string, sender: string, tag: string, limit: number) {
  if (query.length > 200) throw new IntakeError(400, "Search text is too long.");
  if (kind && !KINDS.has(kind)) throw new IntakeError(400, "Kind must be text, file or photo.");
  if (sender.length > 200 || tag.length > 200) throw new IntakeError(400, "That filter is too long.");
  const lim = Math.min(500, Math.max(1, Math.floor(limit || 100)));
  const like = query ? `%${query.replace(/[\\%_]/g, (c) => `\\${c}`)}%` : "";
  const r = await q.query(
    `SELECT id, kind, title, left(coalesce(body, ''), 2000) AS body, original_filename, mime_type,
            size_bytes, sha256, sender, source_machine, tags, project, created_at, archived
       FROM intake_items
      WHERE coalesce(archived, false) = false
        AND ($1 = '' OR kind = $1)
        AND ($2 = '' OR sender ILIKE $2)
        AND ($3 = '' OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(coalesce(tags, '')), ',') AS t(tag) WHERE btrim(tag) = lower($3)))
        AND ($4 = '' OR title ILIKE $4 ESCAPE '\\' OR body ILIKE $4 ESCAPE '\\' OR original_filename ILIKE $4 ESCAPE '\\'
             OR tags ILIKE $4 ESCAPE '\\' OR sender ILIKE $4 ESCAPE '\\' OR project ILIKE $4 ESCAPE '\\')
      ORDER BY created_at DESC, id DESC
      LIMIT $5`,
    [kind, sender, tag, like, lim]);
  return { items: (r.rows as Record<string, unknown>[]).map((row) => shape(row, false)) };
}

async function oneItem(scope: Scope, id: number, full: boolean): Promise<Record<string, unknown>> {
  if (!Number.isInteger(id) || id < 1) throw new IntakeError(400, "That item id is not valid.");
  const r = await pool(scope).query(`SELECT * FROM intake_items WHERE id = $1`, [id]);
  if (!r.rows[0]) throw new IntakeError(404, `No Intake item #${id}.`);
  return shape(r.rows[0] as Record<string, unknown>, full);
}

function blobFile(sha: string): string {
  if (!/^[a-f0-9]{64}$/.test(sha)) throw new IntakeError(404, "No stored file for that item.");
  const dir = path.resolve(requireBlobDir());
  const file = path.resolve(dir, sha);
  if (file !== path.join(dir, sha)) throw new IntakeError(404, "No stored file for that item.");
  return file;
}

export async function shaInfo(sha: string): Promise<Record<string, unknown>> {
  const file = blobFile(sha);
  let st;
  try { st = await stat(file); } catch { throw new IntakeError(404, "No stored file with that sha256."); }
  return { sha256: sha, bytes: st.size, copies: 1 };
}

async function logRead(scope: Scope, via: string, tool: string, ok: boolean, extra: Record<string, unknown>) {
  try {
    await pool(scope).query(
      `INSERT INTO access_log (event_uid, tool, ok, scope, actor, via, session, detail) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [randomUUID(), tool, ok, scope, "intake", via, "intake", JSON.stringify({ client: "intake-http", ...extra })]);
  } catch (e) { console.error(`[intake] access log failed: ${scrub(e)}`); }
}

function send(res: ServerResponse, status: number, body: unknown) {
  const json = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", "content-length": Buffer.byteLength(json) });
  res.end(json);
}

function header(req: IncomingMessage, name: string): string | undefined {
  const v = req.headers[name];
  if (Array.isArray(v)) return v[0];
  return typeof v === "string" ? v : undefined;
}

/** A header value is Latin-1. Non-Latin-1 text arrives as `UTF-8''` plus percent-encoding. */
export function decodeUtf8Header(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const mark = "utf-8''";
  if (raw.length <= mark.length || raw.slice(0, mark.length).toLowerCase() !== mark) return undefined;
  try { return decodeURIComponent(raw.slice(mark.length)); } catch { return undefined; }
}

function headerText(req: IncomingMessage, name: string): string | undefined {
  const decoded = decodeUtf8Header(header(req, name + "-utf8"));
  if (decoded != null && decoded !== "") return decoded;
  return header(req, name);
}

function headerSafe(value: string, fallback: string): string {
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c < 0x20 || c > 0xff) return fallback;
  }
  return value || fallback;
}

/** ASCII fallback plus RFC 5987, so writeHead never sees a non-Latin-1 filename. */
export function attachmentDisposition(name: string): string {
  const dot = name.lastIndexOf(".");
  const ext = dot > 0 ? name.slice(dot) : "";
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const asciiChar = (ch: string) => {
    const c = ch.charCodeAt(0);
    return c >= 0x20 && c <= 0x7e && ch !== '"' && ch !== "\\" ? ch : "_";
  };
  const extOk = ext.length > 1 && [...ext].every((ch) => {
    const c = ch.charCodeAt(0);
    return c >= 0x21 && c <= 0x7e && ch !== '"' && ch !== "\\";
  });
  const fallback = ([...stem].map(asciiChar).join("").replace(/^\.+/, "") || "file") + (extOk ? ext : "");
  const star = encodeURIComponent(name);
  return `attachment; filename="${fallback.slice(0, 180) || "file"}"; filename*=UTF-8''${star}`;
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    const b = c as Buffer;
    n += b.length;
    if (n > 2_000_000) throw new IntakeError(413, "That text is too large to send this way. Send it as a file. Nothing was stored.");
    chunks.push(b);
  }
  const s = Buffer.concat(chunks).toString("utf8");
  if (!s.trim()) return {};
  try {
    const v = JSON.parse(s) as unknown;
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    return v as Record<string, unknown>;
  } catch { throw new IntakeError(400, "The JSON was not readable. Nothing was stored."); }
}

function str(v: unknown): string | undefined {
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return undefined;
}

async function archiveItem(via: string, id: number): Promise<Record<string, unknown>> {
  if (!Number.isInteger(id) || id < 1) throw new IntakeError(400, "That item id is not valid.");
  const t = table();
  const ctx: Ctx = { scope: "write", via, client: "intake-http", defaultSession: "intake" };
  const who: Who = { actor: "intake", session: "archive" };
  const result = await runWrite(ctx, who, "intake_archive", { id }, "intake archive", async (q) => {
    const cur = (await q.query(`SELECT id FROM intake_items WHERE id = $1 FOR UPDATE`, [id])).rows[0];
    if (!cur) throw new IntakeError(404, `No Intake item #${id}. Nothing was changed.`);
    const m = new Map<Field, unknown>();
    put(t, m, "Archived", true);
    await q.query(`UPDATE intake_items SET archived = true WHERE id = $1`, [id]);
    const row = (await q.query(`SELECT * FROM intake_items WHERE id = $1`, [id])).rows[0] as Record<string, unknown>;
    if (comparable(findField(t, "Archived"), row.archived) !== true) throw new Error("archive did not stick");
    return { touched: [{ table: t, id, expect: m, receipt: await receiptFor(q, id, "UPDATE") }] };
  });
  if (!result.ok) throw new IntakeError(400, "Could not archive that item. Nothing was erased.");
  return { id, archived: true, erased: false };
}

export async function handleIntake(req: IncomingMessage, res: ServerResponse, scope: Scope, via: string): Promise<void> {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  const pathname = url.pathname;
  try {
    if (req.headers.expect === "100-continue") res.writeContinue();
    if (req.method === "GET" && pathname === "/intake/disk") {
      const body = await diskInfo();
      await logRead(scope, via, "intake_disk", true, {});
      return send(res, 200, body);
    }
    if (req.method === "GET" && pathname === "/intake/items") {
      const q = url.searchParams;
      const body = await queryItems(pool(scope), q.get("q") || "", q.get("kind") || "", q.get("sender") || "", q.get("tag") || "", Number(q.get("limit") || 100));
      await logRead(scope, via, "intake_list", true, { q: (q.get("q") || "").slice(0, 200), kind: q.get("kind") || "" });
      return send(res, 200, body);
    }
    const one = /^\/intake\/items\/(\d+)$/.exec(pathname);
    if (req.method === "GET" && one) {
      const body = await oneItem(scope, Number(one[1]), true);
      await logRead(scope, via, "intake_get", true, { id: Number(one[1]) });
      return send(res, 200, body);
    }
    const content = /^\/intake\/items\/(\d+)\/content$/.exec(pathname);
    if (req.method === "GET" && content) {
      const item = await oneItem(scope, Number(content[1]), false);
      const file = blobFile(String(item.sha256));
      let st;
      try { st = await stat(file); } catch { throw new IntakeError(404, "The stored file is missing."); }
      const name = safeFilename(typeof item.original_filename === "string" ? item.original_filename : null) || String(item.sha256);
      const mime = headerSafe((typeof item.mime === "string" && item.mime) || "application/octet-stream", "application/octet-stream");
      const disposition = attachmentDisposition(name);
      res.writeHead(200, {
        "content-type": mime,
        "content-length": st.size,
        "content-disposition": disposition,
        "x-intake-filename-utf8": "UTF-8''" + encodeURIComponent(name),
        "x-intake-sha256": String(item.sha256),
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      });
      createReadStream(file).pipe(res);
      await logRead(scope, via, "intake_content", true, { id: Number(content[1]) });
      return;
    }
    const sha = /^\/intake\/sha\/([a-f0-9]{64})$/.exec(pathname);
    if (req.method === "GET" && sha) return send(res, 200, await shaInfo(sha[1]));
    if (req.method === "POST" && pathname === "/intake/items") {
      if (scope !== "write") return send(res, 403, { error: "This token is read-only. Nothing was stored." });
      const type = (header(req, "content-type") || "").split(";")[0].trim().toLowerCase();
      // A .json file is application/json too. A filename header means the body is the file.
      // The text API sends JSON fields and no filename.
      const namedFile = headerText(req, "x-intake-filename");
      if ((type === "application/json" || type.endsWith("+json")) && !namedFile) {
        const j = await readJson(req);
        const body = str(j.body) ?? "";
        const fields: IngestFields = {
          kind: str(j.kind), title: str(j.title), body, filename: str(j.filename), mime: str(j.mime) || "text/plain; charset=utf-8",
          sender: str(j.sender), source_machine: str(j.source_machine), tags: str(j.tags), project: str(j.project),
          tool: "intake_http", via,
        };
        const buf = Buffer.from(body, "utf8");
        const item = await ingestBuffer({ ...fields, kind: fields.kind || "text" }, buf, givenFilename(fields.filename), fields.mime || null, true);
        return send(res, 201, item);
      }
      const declared = header(req, "content-length");
      const len = declared != null && /^\d+$/.test(declared) ? Number(declared) : undefined;
      const filename = givenFilename(headerText(req, "x-intake-filename"));
      const mime = (headerText(req, "x-intake-mime") || type || "application/octet-stream").slice(0, 200);
      const fields: IngestFields = {
        kind: headerText(req, "x-intake-kind"),
        title: headerText(req, "x-intake-title"),
        body: headerText(req, "x-intake-body"),
        filename: filename || undefined,
        mime,
        sender: headerText(req, "x-intake-sender"),
        source_machine: headerText(req, "x-intake-source-machine"),
        tags: headerText(req, "x-intake-tags"),
        project: headerText(req, "x-intake-project"),
        tool: "intake_http", via,
      };
      const meta = await metaFrom(fields, filename, mime, false, fields.body ?? null);
      let stored: Stored | undefined;
      let done = false;
      try {
        stored = await storeStream(req, len);
        const item = await insertItem(meta, stored);
        done = true;
        console.error(`[intake] stored id=${item.id} kind=${meta.kind} bytes=${stored.size} sha256=${stored.sha256.slice(0, 12)} new=${stored.blob_new}`);
        return send(res, 201, item);
      } finally {
        if (stored?.blob_new && !done) await unlink(stored.dest).catch(() => undefined);
      }
    }
    const arch = /^\/intake\/items\/(\d+)\/archive$/.exec(pathname);
    if (req.method === "POST" && arch) {
      if (scope !== "write") return send(res, 403, { error: "This token is read-only. Nothing was changed." });
      return send(res, 200, await archiveItem(via, Number(arch[1])));
    }
    return send(res, 404, { error: "not found" });
  } catch (e) {
    const cause = (e as { cause?: unknown })?.cause;
    const intake = e instanceof IntakeError ? e : cause instanceof IntakeError ? cause : undefined;
    if (intake) {
      if (!res.headersSent) return send(res, intake.status, { error: intake.message });
      return;
    }
    console.error(`[intake] ${scrub(e)}`);
    if (!res.headersSent) {
      const msg = req.method === "GET" ? "Intake could not read that item." : "Intake failed. Nothing was stored.";
      send(res, 500, { error: msg });
    }
  }
}

export async function ingestTool(ctx: Ctx, a: {
  actor: string; kind?: "text" | "file" | "photo"; title?: string; body?: string; filename?: string;
  mime?: string; tags?: string; project?: string; source_machine?: string; sender?: string; content_base64?: string;
}): Promise<Result> {
  try {
    if (a.content_base64 && a.content_base64.length > 11_000_000) {
      return { ok: false, text: "REFUSED -- That file is too large for the MCP tool. Use the Intake HTTP endpoint or ragnarok-intake (up to 5 GB). Nothing was stored." };
    }
    const fields: IngestFields = {
      kind: a.kind, title: a.title, body: a.body, filename: a.filename, mime: a.mime,
      sender: a.sender || a.actor, source_machine: a.source_machine, tags: a.tags, project: a.project,
      tool: "ingest", via: ctx.via,
    };
    let item: Record<string, unknown>;
    if (a.content_base64) {
      const buf = Buffer.from(a.content_base64, "base64");
      if (!buf.length) return { ok: false, text: "REFUSED -- The file contents were empty. Nothing was stored." };
      item = await ingestBuffer(fields, buf, givenFilename(a.filename), a.mime || "application/octet-stream", false);
    } else {
      const body = a.body ?? "";
      item = await ingestBuffer({ ...fields, kind: a.kind || "text" }, Buffer.from(body, "utf8"), givenFilename(a.filename), a.mime || "text/plain; charset=utf-8", true);
    }
    return {
      ok: true,
      text: `CONFIRMED Intake #${item.id} ${item.kind}\nsha256: ${item.sha256}\nblob_new: ${item.blob_new}\nblob_copies: ${item.blob_copies}`,
      data: item,
    };
  } catch (e) {
    if (e instanceof IntakeError) return { ok: false, text: `REFUSED -- ${e.message}` };
    return { ok: false, text: `ERROR -- ${scrub(e)}` };
  }
}
