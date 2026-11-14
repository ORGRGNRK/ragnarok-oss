// What each tool actually does. Pattern for every call:
//   reads : run the query -> add one access_log row -> answer (with the access receipt number)
//   writes: BEGIN -> name the actor -> validate against schema.json -> write -> read the row
//           back and compare every field -> the database trigger adds the write_log receipt
//           -> access_log row -> COMMIT -> read back AGAIN from a fresh connection -> only a
//           full match is reported CONFIRMED. Any problem = ROLLBACK, nothing changed.
import { randomUUID } from "node:crypto";
import type pg from "pg";
import { allowedWriters, approvalTtlHours, type Scope } from "./config.js";
import { pool, scrub } from "./db.js";
import {
  coerce, comparable, findField, findTable, isTexty, present, Refusal,
  type Field, type Schema, type Table,
} from "./schema.js";

export interface Ctx { scope: Scope; via: string; client: string; defaultSession: string }
/** actor and model_claimed are what the CALLER says (never checked); model_reported is only ever set by
 *  this server, from a model API's own response, when the server itself made the model call. */
export interface Who { actor: string; session?: string; model_claimed?: string }
export interface Result { ok: boolean; text: string; data?: Record<string, unknown>; model_reported?: string | null }

const qi = (s: string) => `"${s.replace(/"/g, '""')}"`;
const label = (ctx: Ctx, who: Who) => `${who.actor} via ${ctx.via}`;
const sessionOf = (ctx: Ctx, who: Who) => who.session || ctx.defaultSession;

function argsForLog(args: Record<string, unknown>) {
  const { actor: _a, session: _s, model_claimed: _m, ...rest } = args;
  const s = JSON.stringify(rest);
  return s.length <= 4000 ? rest : { preview: s.slice(0, 4000) + "..." };
}

/** A model name for a receipt column: a string, printable, at most 200 characters; otherwise null. */
export function modelName(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/[^\x20-\x7e]/g, "").trim().slice(0, 200);
  return s || null;
}

export async function logAccess(q: pg.Pool | pg.PoolClient, ctx: Ctx, who: Who, tool: string, ok: boolean, args: Record<string, unknown>, extra: Record<string, unknown> = {}, modelReported: string | null = null): Promise<number> {
  const r = await q.query(
    `INSERT INTO access_log (event_uid, tool, ok, scope, actor, via, session, detail, model_reported, model_claimed) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING seq`,
    [randomUUID(), tool, ok, ctx.scope, who.actor, ctx.via, sessionOf(ctx, who), JSON.stringify({ client: ctx.client, args: argsForLog(args), ...extra }),
     modelName(modelReported), modelName(who.model_claimed)]);
  return Number(r.rows[0].seq);
}

/** Turn a database error into a plain-English refusal when it is a rule, not a crash. */
function friendly(e: any): Refusal | undefined {
  if (e instanceof Refusal) return e;
  const code = e?.code as string | undefined;
  const msg = scrub(e);
  if (code === "23505") return new Refusal(`another record already has that value${e.detail ? ` (${e.detail})` : ""}`);
  if (code === "23502") return new Refusal(`a required field is empty (${e.column ?? msg})`);
  if (code === "23514") return new Refusal(`a value is not allowed by the table's rules (${e.constraint ?? msg})`);
  if (code === "42501") return new Refusal(`not allowed: ${msg}`);
  if (code === "P0001" || code === "P0002" || code === "22023") return new Refusal(msg);
  return undefined;
}

// ------------------------------------------------------------------ wrappers

export async function runRead(ctx: Ctx, who: Who, tool: string, args: Record<string, unknown>, fn: (q: pg.PoolClient) => Promise<Result>): Promise<Result> {
  const q = await pool(ctx.scope).connect();
  try {
    let r: Result;
    try { r = await fn(q); }
    catch (e) { const f = friendly(e); r = { ok: false, text: f ? `REFUSED -- ${f.message}` : `ERROR -- ${scrub(e)}` }; }
    const seq = await logAccess(q, ctx, who, tool, r.ok, args, r.ok ? {} : { error: r.text.slice(0, 500) }, r.model_reported ?? null);
    return { ...r, text: `${r.text}\n\n[access receipt: access_log #${seq}]`, data: { ...(r.data ?? {}), access_log_seq: seq } };
  } finally { q.release(); }
}

interface Touched { table: Table; id: number; expect: Map<Field, unknown>; receipt: { seq: number; receipt_id: string; hash: string }; gone?: boolean }
interface WriteOut { touched: Touched[]; text?: string; data?: Record<string, unknown>; model_reported?: string | null }

export async function runWrite(ctx: Ctx, who: Who, tool: string, args: Record<string, unknown>, note: string | undefined, fn: (q: pg.PoolClient) => Promise<WriteOut>): Promise<Result> {
  if (ctx.scope !== "write") return { ok: false, text: "REFUSED -- this connection is read-only. Nothing was changed.", data: { refused: true } };
  const allow = allowedWriters();
  if (allow.length && !allow.includes(who.actor.trim().toLowerCase()))
    return { ok: false, text: `REFUSED -- "${who.actor}" is not on this server's list of actors allowed to write (ALLOWED_WRITE_ACTORS). Nothing was changed.`, data: { refused: true } };
  const p = pool(ctx.scope);
  const q = await p.connect();
  let out: WriteOut; let accessSeq: number;
  try {
    await q.query("BEGIN");
    try {
      await q.query("SELECT set_config('receipt.actor', $1, true), set_config('receipt.session', $2, true), set_config('receipt.note', $3, true)",
        [label(ctx, who), sessionOf(ctx, who), note ?? ""]);
      out = await fn(q);
      accessSeq = await logAccess(q, ctx, who, tool, true, args, { receipts: out.touched.map((t) => t.receipt.receipt_id) }, out.model_reported ?? null);
      await q.query("COMMIT");
    } catch (e) {
      await q.query("ROLLBACK").catch(() => undefined);
      const f = friendly(e);
      const msg = f ? f.message : scrub(e);
      const seq = await logAccess(p, ctx, who, tool, false, args, { error: msg.slice(0, 500) }).catch(() => undefined);
      return {
        ok: false,
        text: `${f ? "REFUSED" : "WRITE FAILED"} -- nothing was changed. ${msg}${seq ? `\n[the attempt is logged: access_log #${seq}]` : ""}`,
        data: { refused: !!f, error: msg, access_log_seq: seq },
      };
    }
  } finally { q.release(); }

  // Second read-back, after COMMIT, on a fresh connection: is it really there, and is the receipt?
  const lines: string[] = []; const results: Record<string, unknown>[] = []; let allOk = true;
  for (const t of out.touched) {
    const row = (await p.query(`SELECT * FROM ${qi(t.table.sql_name)} WHERE id = $1`, [t.id])).rows[0];
    const rc = (await p.query(`SELECT seq FROM write_log WHERE receipt_id = $1`, [t.receipt.receipt_id])).rows[0];
    let status: string; const bad: string[] = [];
    if (t.gone) {
      status = !row && rc ? "CONFIRMED" : "UNCONFIRMED";
      if (row) bad.push("record is still in the table");
    } else if (!row) { status = "UNCONFIRMED"; bad.push("record not found after saving"); }
    else {
      for (const [f, v] of t.expect) if (comparable(f, row[f.column]) !== comparable(f, v)) bad.push(`${f.name}: wanted ${JSON.stringify(v)}, database has ${JSON.stringify(row[f.column])}`);
      status = bad.length ? "UNCONFIRMED" : "CONFIRMED";
    }
    if (!rc) bad.push("receipt not found");
    if (status !== "CONFIRMED") allOk = false;
    const n = t.expect.size;
    lines.push(`${status}  ${t.table.name} #${t.id}${t.gone ? " archived" : ` -- ${n - bad.length}/${n} fields read back and match`}${bad.length ? ` -- PROBLEM: ${bad.join("; ")}` : ""}\n` +
      `  RECEIPT ${t.receipt.receipt_id} (write_log #${t.receipt.seq}, hash ${t.receipt.hash.slice(0, 16)}...)` +
      (row ? `\n  ${JSON.stringify(present(t.table, row))}` : ""));
    results.push({ table: t.table.name, id: t.id, status, receipt_id: t.receipt.receipt_id, write_log_seq: t.receipt.seq, hash: t.receipt.hash, problems: bad, record: row ? present(t.table, row) : null });
  }
  return {
    ok: allOk,
    text: `${out.text ? out.text + "\n" : ""}${lines.join("\n")}\n\nactor: ${label(ctx, who)}\n[access receipt: access_log #${accessSeq}]`,
    data: { ...(out.data ?? {}), status: allOk ? "CONFIRMED" : "UNCONFIRMED", results, access_log_seq: accessSeq },
  };
}

// ------------------------------------------------------------------ helpers

async function receiptFor(q: pg.PoolClient, t: Table, id: number, action: string) {
  // The chain trigger holds a lock on write_log until COMMIT, so the newest row for this record is ours.
  const r = (await q.query(`SELECT seq, receipt_id, hash, action FROM write_log WHERE table_name = $1 AND record_id = $2 ORDER BY seq DESC LIMIT 1`, [t.sql_name, String(id)])).rows[0];
  if (!r || r.action !== action) throw new Error(`no ${action} receipt was produced for ${t.name} #${id} -- rolled back`);
  return { seq: Number(r.seq), receipt_id: r.receipt_id as string, hash: r.hash as string };
}

function mapFields(t: Table, rec: Record<string, unknown>, forCreate: boolean): Map<Field, unknown> {
  const m = new Map<Field, unknown>();
  for (const [k, v] of Object.entries(rec)) {
    if (k.toLowerCase() === "id") continue;
    const f = findField(t, k);
    if (!f.writable) throw new Refusal(`${f.name} is read-only for the AI`);
    if (m.has(f)) throw new Refusal(`${f.name} is given twice`);
    m.set(f, coerce(f, v));
  }
  if (forCreate) for (const f of t.fields) if (f.required && (f.default === undefined || f.default === null) && !m.has(f)) throw new Refusal(`${f.name} is required`);
  return m;
}

function readBackCheck(t: Table, row: Record<string, unknown> | undefined, expect: Map<Field, unknown>, id: number) {
  if (!row) throw new Error(`read-back: ${t.name} #${id} not found inside the transaction -- rolled back`);
  const bad = [...expect].filter(([f, v]) => comparable(f, row[f.column]) !== comparable(f, v)).map(([f, v]) => `${f.name} (sent ${JSON.stringify(v)}, stored ${JSON.stringify(row[f.column])})`);
  if (bad.length) throw new Refusal(`read-back did not match, so nothing was saved: ${bad.join("; ")}`);
}

const fmtRows = (t: Table, rows: Record<string, unknown>[], only?: Field[]) => rows.map((r) => {
  const p = present(t, r);
  if (!only) return JSON.stringify(p);
  const o: Record<string, unknown> = { Id: p.Id };
  for (const f of only) o[f.name] = p[f.name];
  return JSON.stringify(o);
}).join("\n");

function whereFromFilter(t: Table, filter: Record<string, unknown> | undefined, params: unknown[]): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(filter ?? {})) {
    if (k.toLowerCase() === "id") { params.push(Number(v)); parts.push(`id = $${params.length}`); continue; }
    const f = findField(t, k);
    if (v === null) { parts.push(`${qi(f.column)} IS NULL`); continue; }
    const cv = coerce({ ...f, required: false }, v);
    if (cv === null) { parts.push(`${qi(f.column)} IS NULL`); continue; }
    params.push(cv); parts.push(`${qi(f.column)} = $${params.length}`);
  }
  return parts.length ? `WHERE ${parts.join(" AND ")}` : "";
}

function orderBy(t: Table, sort?: string): string {
  if (!sort || !sort.trim()) return "ORDER BY id";
  const desc = sort.trim().startsWith("-");
  const name = sort.trim().replace(/^[-+]/, "");
  const col = name.toLowerCase() === "id" ? "id" : ["created", "updated"].includes(name.toLowerCase()) ? `${name.toLowerCase()}_at` : qi(findField(t, name).column);
  return `ORDER BY ${col} ${desc ? "DESC" : "ASC"} NULLS LAST, id`;
}

// ------------------------------------------------------------------ reads

export async function listTables(q: pg.PoolClient, s: Schema): Promise<Result> {
  const known = new Set((await q.query(`SELECT sql_name FROM kit_tables`)).rows.map((r) => r.sql_name));
  const out: { table: string; records: number | null; fields: number }[] = [];
  for (const t of s.tables) {
    const n = known.has(t.sql_name) ? Number((await q.query(`SELECT count(*) AS n FROM ${qi(t.sql_name)}`)).rows[0].n) : null;
    out.push({ table: t.name, records: n, fields: t.fields.length });
  }
  const text = `${s.client}: ${s.tables.length} table(s)\n` + out.map((o) => `- ${o.table}: ${o.records === null ? "NOT CREATED YET (run ./kit up)" : `${o.records} records`}, ${o.fields} fields`).join("\n");
  return { ok: true, text, data: { client: s.client, tables: out } };
}

export function describeTable(s: Schema, name: string): Result {
  const t = findTable(s, name);
  const fields = [
    { name: "Id", type: "integer", required: false, unique: true, writable: false, description: "row number, set by the database" },
    ...t.fields.map((f) => ({ name: f.name, type: f.type, required: f.required, unique: f.unique, writable: f.writable, choices: f.choices, default: f.default, description: f.description })),
  ];
  const text = `${t.name}${t.description ? ` -- ${t.description}` : ""}\n` + fields.map((f: any) =>
    `- ${f.name}: ${f.type}${f.required ? ", required" : ""}${f.unique ? ", unique" : ""}${f.writable ? "" : ", read-only"}${f.choices ? `, one of: ${f.choices.join(" | ")}` : ""}${f.default !== undefined && f.default !== null ? `, default ${JSON.stringify(f.default)}` : ""}${f.description ? ` -- ${f.description}` : ""}`).join("\n") +
    `\nAlso on every record: Created, Updated (set by the database).`;
  return { ok: true, text, data: { table: t.name, fields } };
}

export async function listRecords(q: pg.PoolClient, s: Schema, a: { table: string; fields?: string[]; filter?: Record<string, unknown>; sort?: string; limit?: number }): Promise<Result> {
  const t = findTable(s, a.table);
  const only = a.fields?.length ? a.fields.filter((n) => n.toLowerCase() !== "id").map((n) => findField(t, n)) : undefined;
  const params: unknown[] = [];
  const where = whereFromFilter(t, a.filter, params);
  const limit = Math.min(a.limit ?? 100, 1000);
  const total = Number((await q.query(`SELECT count(*) AS n FROM ${qi(t.sql_name)} ${where}`, params)).rows[0].n);
  const rows = (await q.query(`SELECT * FROM ${qi(t.sql_name)} ${where} ${orderBy(t, a.sort)} LIMIT ${limit}`, params)).rows;
  const head = `${t.name}: showing ${rows.length} of ${total} matching record(s)${rows.length < total ? ` (limit ${limit}; raise limit or filter to see the rest)` : ""}`;
  return { ok: true, text: `${head}\n${fmtRows(t, rows, only)}`, data: { table: t.name, total, shown: rows.length, records: rows.map((r) => present(t, r)) } };
}

export async function getRecord(q: pg.PoolClient, s: Schema, a: { table: string; id?: number; field?: string; value?: string }): Promise<Result> {
  const t = findTable(s, a.table);
  let rows: Record<string, unknown>[];
  if (a.id !== undefined) rows = (await q.query(`SELECT * FROM ${qi(t.sql_name)} WHERE id = $1`, [a.id])).rows;
  else if (a.field && a.value !== undefined) {
    const f = findField(t, a.field);
    rows = (await q.query(`SELECT * FROM ${qi(t.sql_name)} WHERE ${qi(f.column)} = $1 LIMIT 2`, [coerce({ ...f, required: false }, a.value)])).rows;
    if (rows.length > 1) throw new Refusal(`more than one ${t.name} record has ${f.name} = ${JSON.stringify(a.value)}; use data_list_records with a filter, or data_get_record by Id`);
  } else throw new Refusal("give either id, or field + value");
  if (!rows[0]) return { ok: false, text: `not found: no ${t.name} record matches` };
  const history = (await q.query(`SELECT seq, receipt_id, action, actor, note, created_at FROM write_log WHERE table_name = $1 AND record_id = $2 ORDER BY seq`, [t.sql_name, String(rows[0].id)])).rows;
  const h = history.map((r) => `  #${r.seq} ${r.action} by ${r.actor} at ${new Date(r.created_at).toISOString()}${r.note ? ` -- ${r.note}` : ""} (${r.receipt_id})`).join("\n");
  return { ok: true, text: `${JSON.stringify(present(t, rows[0]))}\nhistory (${history.length} receipt(s)):\n${h}`, data: { record: present(t, rows[0]), history } };
}

export async function searchRecords(q: pg.PoolClient, s: Schema, a: { table: string; query: string; fields?: string[]; limit?: number }): Promise<Result> {
  const t = findTable(s, a.table);
  const fields = a.fields?.length ? a.fields.map((n) => findField(t, n)) : t.fields.filter(isTexty);
  if (!fields.length) throw new Refusal(`${t.name} has no text fields to search; name the fields to search`);
  const pat = `%${a.query.replace(/[\\%_]/g, (c) => "\\" + c)}%`;
  const where = `WHERE ${fields.map((f) => `${qi(f.column)}::text ILIKE $1`).join(" OR ")}`;
  const limit = Math.min(a.limit ?? 50, 500);
  const total = Number((await q.query(`SELECT count(*) AS n FROM ${qi(t.sql_name)} ${where}`, [pat])).rows[0].n);
  const rows = (await q.query(`SELECT * FROM ${qi(t.sql_name)} ${where} ORDER BY id LIMIT ${limit}`, [pat])).rows;
  return { ok: true, text: `${t.name}: ${total} match(es) for "${a.query}" in ${fields.map((f) => f.name).join(", ")}${rows.length < total ? ` (showing ${rows.length})` : ""}\n${fmtRows(t, rows)}`, data: { total, shown: rows.length, records: rows.map((r) => present(t, r)) } };
}

export async function verifyReceipts(q: pg.PoolClient): Promise<Result> {
  const rows = (await q.query(`SELECT * FROM kit_verify()`)).rows;
  const good = rows.every((r) => r.intact && r.lock_on);
  const text = rows.map((r) =>
    `${r.intact ? "INTACT" : "BROKEN"}  ${r.chain}: ${r.rows_checked} rows${r.intact ? `, head ${r.head_hash ?? "(empty)"}` : `, first bad row #${r.first_bad_seq}: ${r.problem}`}\n` +
    `  lock: ${r.lock_on ? "ON (UPDATE/DELETE/TRUNCATE refused)" : `OFF -- ${r.lock_problem}`}`).join("\n") +
    `\n${good ? "All receipts intact and locked." : "PROBLEM: the receipt log was altered or unlocked outside the normal path."}` +
    `\nTip: save the head hashes somewhere outside this server now and then; a full rewrite of history would no longer match them.`;
  return { ok: true, text, data: { intact: good, chains: rows } };
}

// ------------------------------------------------------------------ writes

export function createRecords(ctx: Ctx, who: Who, s: Schema, a: { table: string; records: Record<string, unknown>[]; note?: string }, args: Record<string, unknown>) {
  return runWrite(ctx, who, "data_create_records", args, a.note, async (q) => {
    const t = findTable(s, a.table);
    const touched: Touched[] = [];
    for (const [i, rec] of a.records.entries()) {
      if (Object.keys(rec).some((k) => k.toLowerCase() === "id")) throw new Refusal(`record ${i + 1}: don't send Id when creating; the database picks it`);
      let m: Map<Field, unknown>;
      try { m = mapFields(t, rec, true); } catch (e) { throw e instanceof Refusal ? new Refusal(`record ${i + 1}: ${e.message}`) : e; }
      const cols = [...m.keys()].map((f) => qi(f.column));
      const sql = cols.length
        ? `INSERT INTO ${qi(t.sql_name)} (${cols.join(", ")}) VALUES (${cols.map((_, j) => `$${j + 1}`).join(", ")}) RETURNING id`
        : `INSERT INTO ${qi(t.sql_name)} DEFAULT VALUES RETURNING id`;
      const id = Number((await q.query(sql, [...m.values()])).rows[0].id);
      const row = (await q.query(`SELECT * FROM ${qi(t.sql_name)} WHERE id = $1`, [id])).rows[0];
      readBackCheck(t, row, m, id);
      touched.push({ table: t, id, expect: m, receipt: await receiptFor(q, t, id, "INSERT") });
    }
    return { touched, text: `Created ${touched.length} ${t.name} record(s).` };
  });
}

export function updateRecords(ctx: Ctx, who: Who, s: Schema, a: { table: string; records: Record<string, unknown>[]; note?: string }, args: Record<string, unknown>) {
  return runWrite(ctx, who, "data_update_records", args, a.note, async (q) => {
    const t = findTable(s, a.table);
    const touched: Touched[] = []; const seen = new Set<number>();
    for (const [i, rec] of a.records.entries()) {
      const idKey = Object.keys(rec).find((k) => k.toLowerCase() === "id");
      const id = idKey ? Number(rec[idKey]) : NaN;
      if (!Number.isSafeInteger(id) || id < 1) throw new Refusal(`record ${i + 1}: needs "Id" (the row number from data_list_records)`);
      if (seen.has(id)) throw new Refusal(`record ${i + 1}: Id ${id} appears twice`);
      seen.add(id);
      let m: Map<Field, unknown>;
      try { m = mapFields(t, rec, false); } catch (e) { throw e instanceof Refusal ? new Refusal(`record ${i + 1} (Id ${id}): ${e.message}`) : e; }
      if (m.size === 0) throw new Refusal(`record ${i + 1} (Id ${id}): no fields to change`);
      const cur = (await q.query(`SELECT id FROM ${qi(t.sql_name)} WHERE id = $1 FOR UPDATE`, [id])).rows[0];
      if (!cur) throw new Refusal(`record ${i + 1}: no ${t.name} record with Id ${id}`);
      const cols = [...m.keys()].map((f) => qi(f.column));
      await q.query(`UPDATE ${qi(t.sql_name)} SET ${cols.map((c, j) => `${c} = $${j + 2}`).join(", ")} WHERE id = $1`, [id, ...m.values()]);
      const row = (await q.query(`SELECT * FROM ${qi(t.sql_name)} WHERE id = $1`, [id])).rows[0];
      readBackCheck(t, row, m, id);
      touched.push({ table: t, id, expect: m, receipt: await receiptFor(q, t, id, "UPDATE") });
    }
    return { touched, text: `Updated ${touched.length} ${t.name} record(s).` };
  });
}

export async function archiveRecord(ctx: Ctx, who: Who, s: Schema, a: { table: string; id: number; reason: string; approval_code?: string }, args: Record<string, unknown>): Promise<Result> {
  const t = findTable(s, a.table);
  if (!a.approval_code) {
    // Step 1: ask for a code. The request itself is receipted (approvals table) but nothing is removed.
    let code = "";
    const r = await runWrite(ctx, who, "data_archive_record", args, a.reason, async (q) => {
      code = (await q.query(`SELECT kit_request_archive($1, $2, $3, $4, $5) AS c`, [t.sql_name, a.id, a.reason, label(ctx, who), approvalTtlHours()])).rows[0].c;
      const rc = (await q.query(`SELECT seq, receipt_id, hash FROM write_log WHERE table_name = 'approvals' AND record_id = $1 ORDER BY seq DESC LIMIT 1`, [code])).rows[0];
      return { touched: [], data: { approval_code: code, approval_receipt: rc?.receipt_id } };
    });
    if (!r.ok) return r;
    return {
      ok: true,
      text: `NOT ARCHIVED YET -- a person has to approve this first. Nothing was removed.\n` +
        `Approval code: ${code} (for ${t.name} #${a.id}, expires in ${approvalTtlHours()}h)\n` +
        `Ask the owner to run this in a terminal on the server, in the kit folder:\n  ./kit approve ${code}\n` +
        `Then call data_archive_record again with approval_code "${code}".\n${r.text.split("\n").filter((l) => l.startsWith("[access")).join("\n")}`,
      data: { status: "APPROVAL_REQUIRED", approval_code: code, archived: false, access_log_seq: r.data?.access_log_seq },
    };
  }
  // Step 2: the database checks the code (approved? right record? unused? not expired?), copies the
  // whole record into archive, removes it, and burns the code -- all in one transaction.
  return runWrite(ctx, who, "data_archive_record", args, a.reason, async (q) => {
    const archiveId = Number((await q.query(`SELECT kit_archive($1, $2, $3, $4, $5) AS id`, [t.sql_name, a.id, a.approval_code, a.reason, label(ctx, who)])).rows[0].id);
    const arch = (await q.query(`SELECT record FROM archive WHERE id = $1`, [archiveId])).rows[0];
    if (!arch || Number(arch.record?.id) !== a.id) throw new Error("archive copy not found after archiving -- rolled back");
    return {
      touched: [{ table: t, id: a.id, expect: new Map(), receipt: await receiptFor(q, t, a.id, "DELETE"), gone: true }],
      text: `Archived ${t.name} #${a.id} (copy kept in archive #${archiveId}, approval ${String(a.approval_code).toUpperCase()} used).`,
      data: { archive_id: archiveId, archived: true },
    };
  });
}
