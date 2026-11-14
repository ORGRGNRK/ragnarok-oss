// End-to-end test. Runs INSIDE the throwaway test stack that scripts/test.sh builds (never on a
// client's real data: it edits the receipt log on purpose to prove tampering is caught).
// It works for any client/schema.json: test values are generated from the first table's fields.
import { randomBytes } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import pg from "pg";
import { loadSchema, type Field } from "../src/schema.js";

const E = process.env;
const URL_ = E.TEST_MCP_URL || "http://mcp:8787/mcp";
const ACTOR = "e2e-test";
let passed = 0; const failed: string[] = [];
const check = (name: string, cond: unknown, detail = "") => {
  if (cond) { passed++; console.log(`  PASS  ${name}`); }
  else { failed.push(name); console.log(`  FAIL  ${name}${detail ? `  -- ${String(detail).slice(0, 400)}` : ""}`); }
};
const section = (s: string) => console.log(`\n== ${s}`);

const admin = new pg.Pool({ host: E.DB_HOST || "postgres", port: 5432, database: E.POSTGRES_DB, user: E.TEST_ADMIN_USER, password: E.TEST_ADMIN_PASSWORD, max: 2 });
const asRole = (user?: string, password?: string) => new pg.Pool({ host: E.DB_HOST || "postgres", port: 5432, database: E.POSTGRES_DB, user, password, max: 1 });
const one = async (sql: string, p: unknown[] = []) => (await admin.query(sql, p)).rows[0];
const wlCount = async () => Number((await one(`SELECT count(*) AS n FROM write_log`)).n);
const pgErr = async (p: pg.Pool, sql: string) => { try { await p.query(sql); return null; } catch (e: any) { return e as { code?: string; message: string }; } };

type Call = (name: string, args?: Record<string, unknown>) => Promise<{ isError: boolean; text: string; data: any }>;
async function connectHttp(token?: string): Promise<{ client: Client; call: Call; close: () => Promise<void> }> {
  const transport = new StreamableHTTPClientTransport(new URL(URL_), token ? { requestInit: { headers: { Authorization: `Bearer ${token}` } } } : undefined);
  const client = new Client({ name: "e2e-http", version: "1.0.0" });
  await client.connect(transport);
  return wrap(client);
}
async function connectStdio(scope: "read" | "write") {
  const transport = new StdioClientTransport({ command: "node", args: ["dist/src/stdio.js"], env: { ...(E as Record<string, string>), KIT_SCOPE: scope, MCP_USER_LABEL: "e2e", MCP_HOST_LABEL: "test" }, stderr: "ignore" });
  const client = new Client({ name: "e2e-stdio", version: "1.0.0" });
  await client.connect(transport);
  return wrap(client);
}
function wrap(client: Client) {
  const call: Call = async (name, args = {}) => {
    try {
      const r: any = await client.callTool({ name, arguments: { actor: ACTOR, ...args } });
      return { isError: !!r.isError, text: (r.content?.[0]?.text as string) ?? "", data: r.structuredContent ?? {} };
    } catch (e: any) { return { isError: true, text: `THROWN: ${e.message}`, data: {} }; }
  };
  return { client, call, close: () => client.close() };
}

// ---- values generated from the schema
const s = loadSchema();
const t = s.tables[0];
const tag = `e2e${randomBytes(3).toString("hex")}`;
function sample(f: Field, n: number): unknown {
  switch (f.type) {
    case "text": return `${tag}-${f.unique ? n : "v"}${n}`.slice(0, f.max_length ?? 500);
    case "long_text": return `${tag} long text ${n}`;
    case "email": return `${tag}.${n}@example.com`;
    case "url": return `https://example.com/${tag}/${n}`;
    case "integer": return 10 + n;
    case "number": return 1.5 + n;
    case "money": return 12.34 + n;
    case "boolean": return n % 2 === 0;
    case "date": return `2026-01-${String(10 + n).padStart(2, "0")}`;
    case "datetime": return `2026-01-${String(10 + n).padStart(2, "0")}T10:00:00.000Z`;
    case "select": return f.choices![n % f.choices!.length];
  }
}
const writable = t.fields.filter((f) => f.writable);
const record = (n: number) => Object.fromEntries(writable.map((f) => [f.name, sample(f, n)]));
const uniqueField = writable.find((f) => f.unique && (f.type === "text" || f.type === "email")) ?? writable.find((f) => f.type === "text");
const updField = writable.find((f) => !f.unique && ["text", "long_text", "integer", "number", "money"].includes(f.type)) ?? writable.find((f) => !f.unique)!;
const selectField = writable.find((f) => f.type === "select");
const requiredField = writable.find((f) => f.required && (f.default === undefined || f.default === null));

async function main() {
  console.log(`client-kit end-to-end test -- schema "${s.client}", testing table "${t.name}"`);

  section("1. Remote access needs a valid token");
  const health = await fetch(URL_.replace(/\/mcp$/, "/health"));
  check("GET /health answers without a token", health.status === 200);
  const init = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "raw", version: "0" } } };
  const hdr = { "content-type": "application/json", accept: "application/json, text/event-stream" };
  const noTok = await fetch(URL_, { method: "POST", headers: hdr, body: JSON.stringify(init) });
  check("POST /mcp with NO token is refused (401)", noTok.status === 401, `status ${noTok.status}`);
  const badTok = await fetch(URL_, { method: "POST", headers: { ...hdr, authorization: `Bearer ${"x".repeat(64)}` }, body: JSON.stringify(init) });
  check("POST /mcp with a WRONG token is refused (401)", badTok.status === 401, `status ${badTok.status}`);
  const badScheme = await fetch(URL_, { method: "POST", headers: { ...hdr, authorization: `Basic ${Buffer.from("a:b").toString("base64")}` }, body: JSON.stringify(init) });
  check("POST /mcp with a non-Bearer header is refused (401)", badScheme.status === 401);
  const badBody = await badTok.text();
  check("the refusal does not echo any token", !badBody.includes(E.MCP_TOKEN!) && !badBody.includes("x".repeat(64)));
  let anon: unknown;
  try { await connectHttp(); anon = "connected"; } catch (e: any) { anon = e.message; }
  check("an MCP client without a token cannot connect", anon !== "connected", String(anon));

  section("2. Tools offered per scope");
  const W = await connectHttp(E.MCP_TOKEN);
  const R = await connectHttp(E.MCP_READ_TOKEN);
  const wTools = (await W.client.listTools()).tools.map((x) => x.name).sort();
  const rTools = (await R.client.listTools()).tools.map((x) => x.name).sort();
  const READS = ["describe_table", "get_record", "list_records", "list_tables", "search_records", "verify_receipts"];
  check("write token sees all 9 tools", JSON.stringify(wTools) === JSON.stringify([...READS, "archive_record", "create_records", "update_records"].sort()), wTools.join(","));
  check("read-only token sees only the 6 read tools", JSON.stringify(rTools) === JSON.stringify(READS), rTools.join(","));

  section("3. Reads");
  const lt = await W.call("list_tables");
  check("list_tables works and names the table", !lt.isError && lt.text.includes(t.name), lt.text);
  const dt = await W.call("describe_table", { table: t.name });
  check("describe_table lists every field", !dt.isError && t.fields.every((f) => dt.text.includes(f.name)), dt.text);
  const ev = await one(`SELECT tool, ok, scope, actor, via FROM access_log WHERE seq = $1`, [dt.data.access_log_seq]);
  check("every read leaves an access_log row (tool, actor, token used)", ev?.tool === "describe_table" && ev?.ok === true && ev?.actor === ACTOR && String(ev?.via).startsWith("http:write-token"), JSON.stringify(ev));

  section("4. Create -> read back -> receipt");
  const before = await wlCount();
  const rec1 = record(1);
  const c = await W.call("create_records", { table: t.name, records: [rec1], note: "e2e create" });
  check("create_records is CONFIRMED", !c.isError && c.data.status === "CONFIRMED" && /CONFIRMED/.test(c.text), c.text);
  const created = c.data.results?.[0];
  const id = created?.id as number;
  check(`create reports ${writable.length}/${writable.length} fields read back`, c.text.includes(`${writable.length}/${writable.length} fields read back and match`), c.text);
  const w1 = await one(`SELECT action, table_name, record_id, new_value, actor, note FROM write_log WHERE receipt_id = $1`, [created?.receipt_id]);
  check("the receipt exists in write_log with the new values", w1?.action === "INSERT" && w1?.table_name === t.sql_name && Number(w1?.record_id) === id && writable.every((f) => w1.new_value[f.column] !== undefined), JSON.stringify(w1));
  check("the receipt names the actor, how they connected, and the note", String(w1?.actor).startsWith(`${ACTOR} via http:write-token`) && w1?.note === "e2e create", w1?.actor);
  check("exactly one data receipt for one created record", (await wlCount()) === before + 1);

  const g = await W.call("get_record", { table: t.name, id });
  check("get_record finds it, with its history", !g.isError && g.data.record?.Id === id && g.data.history?.length === 1, g.text);
  if (uniqueField) {
    const l = await W.call("list_records", { table: t.name, filter: { [uniqueField.name]: rec1[uniqueField.name] } });
    check("list_records filter finds exactly it", !l.isError && l.data.total === 1 && l.data.records?.[0]?.Id === id, l.text);
    const gf = await W.call("get_record", { table: t.name, field: uniqueField.name, value: String(rec1[uniqueField.name]) });
    check("get_record by field value works", !gf.isError && gf.data.record?.Id === id, gf.text);
  }
  const sr = await W.call("search_records", { table: t.name, query: tag });
  check("search_records finds it", !sr.isError && sr.data.total >= 1 && sr.data.records.some((r: any) => r.Id === id), sr.text);

  section("5. Update -> read back -> receipt with old and new value");
  const newVal = sample(updField, 7);
  const u = await W.call("update_records", { table: t.name, records: [{ Id: id, [updField.name]: newVal }], note: "e2e update" });
  check("update_records is CONFIRMED", !u.isError && u.data.status === "CONFIRMED", u.text);
  const w2 = await one(`SELECT action, old_value, new_value FROM write_log WHERE receipt_id = $1`, [u.data.results?.[0]?.receipt_id]);
  check("update receipt keeps the old AND new value", w2?.action === "UPDATE" && String(w2.old_value[updField.column]) === String((await one(`SELECT new_value FROM write_log WHERE receipt_id=$1`, [created.receipt_id])).new_value[updField.column]) && String(w2.new_value[updField.column]) === String(newVal), JSON.stringify(w2));

  section("6. Bad writes are refused and change nothing");
  const n0 = await wlCount();
  const r1 = await W.call("update_records", { table: t.name, records: [{ Id: id, "No Such Field": 1 }] });
  check("unknown field -> REFUSED", r1.isError && /REFUSED/.test(r1.text), r1.text);
  if (selectField) {
    const r2 = await W.call("update_records", { table: t.name, records: [{ Id: id, [selectField.name]: "not-a-choice" }] });
    check("value not in a select's choices -> REFUSED", r2.isError && /REFUSED/.test(r2.text), r2.text);
  }
  if (requiredField) {
    const partial = record(3); delete partial[requiredField.name];
    const r3 = await W.call("create_records", { table: t.name, records: [partial] });
    check(`missing required field (${requiredField.name}) -> REFUSED`, r3.isError && /REFUSED/.test(r3.text), r3.text);
  }
  const r4 = await W.call("update_records", { table: t.name, records: [{ Id: 99999999, [updField.name]: newVal }] });
  check("update of a record that doesn't exist -> REFUSED", r4.isError && /REFUSED/.test(r4.text), r4.text);
  const r5 = await W.call("create_records", { table: t.name, records: [record(4), { ...record(5), "No Such Field": 1 }] });
  check("batch with one bad record -> nothing from the batch is saved", r5.isError && (await one(`SELECT count(*) AS n FROM "${t.sql_name}" WHERE ${uniqueField ? `"${uniqueField.column}" = $1` : "false"}`, [record(4)[uniqueField?.name ?? ""]])).n == 0, r5.text);
  check("refused writes added no data receipts", (await wlCount()) === n0, `${n0} -> ${await wlCount()}`);
  const refusedEv = await one(`SELECT count(*) AS n FROM access_log WHERE ok = false AND actor = $1`, [ACTOR]);
  check("refused attempts are still logged in access_log", Number(refusedEv.n) >= 3);

  section("7. Read-only scope refuses writes");
  const n1 = await wlCount();
  const ro1 = await R.call("create_records", { table: t.name, records: [record(6)] });
  check("read-only token: create_records is refused", ro1.isError, ro1.text);
  const ro2 = await R.call("update_records", { table: t.name, records: [{ Id: id, [updField.name]: sample(updField, 8) }] });
  check("read-only token: update_records is refused", ro2.isError, ro2.text);
  const ro3 = await R.call("archive_record", { table: t.name, id, reason: "x" });
  check("read-only token: archive_record is refused", ro3.isError, ro3.text);
  check("read-only token: nothing was written", (await wlCount()) === n1);
  const ro4 = await R.call("list_records", { table: t.name, limit: 5 });
  check("read-only token: reads still work", !ro4.isError && ro4.data.total >= 1, ro4.text);
  const roEv = await one(`SELECT scope, via FROM access_log WHERE seq = $1`, [ro4.data.access_log_seq]);
  check("read-only calls are logged as scope=read via read-token", roEv?.scope === "read" && String(roEv?.via).startsWith("http:read-token"), JSON.stringify(roEv));
  const roPool = asRole(E.MCP_RO_DB_USER, E.MCP_RO_DB_PASSWORD);
  const roIns = await pgErr(roPool, `UPDATE "${t.sql_name}" SET id = id WHERE false`);
  check("read-only DATABASE login itself can't write (permission denied)", roIns?.code === "42501", roIns?.message ?? "no error");
  await roPool.end();
  const S1 = await connectStdio("read");
  const sTools = (await S1.client.listTools()).tools.map((x) => x.name).sort();
  check("stdio with KIT_SCOPE=read hides write tools", JSON.stringify(sTools) === JSON.stringify(READS), sTools.join(","));
  const sRead = await S1.call("list_tables");
  check("stdio read-only: reads work", !sRead.isError, sRead.text);
  await S1.close();
  const S2 = await connectStdio("write");
  const sw = await S2.call("update_records", { table: t.name, records: [{ Id: id, [updField.name]: sample(updField, 9) }] });
  check("stdio write scope: update CONFIRMED", !sw.isError && sw.data.status === "CONFIRMED", sw.text);
  const sww = await one(`SELECT actor FROM write_log WHERE receipt_id = $1`, [sw.data.results?.[0]?.receipt_id]);
  check("stdio receipts say stdio:<user>@<machine>", String(sww?.actor).includes("via stdio:e2e@test"), sww?.actor);
  await S2.close();

  section("8. Delete = archive, and only with a human-approved code");
  const rwPool = asRole(E.MCP_DB_USER, E.MCP_DB_PASSWORD);
  const del = await pgErr(rwPool, `DELETE FROM "${t.sql_name}" WHERE id = ${id}`);
  check("the AI's database login has no DELETE permission", del?.code === "42501", del?.message ?? "no error");
  const a0 = await W.call("archive_record", { table: t.name, id, reason: "e2e archive" });
  const code = a0.data.approval_code as string;
  check("archive without a code -> APPROVAL_REQUIRED, nothing removed", a0.data.status === "APPROVAL_REQUIRED" && !!code && !!(await one(`SELECT id FROM "${t.sql_name}" WHERE id = $1`, [id])), a0.text);
  const a1 = await W.call("archive_record", { table: t.name, id, reason: "e2e", approval_code: code });
  check("archive with the code BEFORE a person approves -> REFUSED", a1.isError && /not been approved/.test(a1.text) && !!(await one(`SELECT id FROM "${t.sql_name}" WHERE id = $1`, [id])), a1.text);
  const a2 = await W.call("archive_record", { table: t.name, id, reason: "e2e", approval_code: "ARC-MADEUP99" });
  check("archive with a made-up code -> REFUSED", a2.isError && /REFUSED/.test(a2.text), a2.text);
  const selfApprove = await pgErr(rwPool, `SELECT kit_approve('${code}', 'ai')`);
  check("the AI's login cannot approve its own request", selfApprove?.code === "42501", selfApprove?.message ?? "no error");
  const selfUpd = await pgErr(rwPool, `UPDATE approvals SET approved_at = now() WHERE code = '${code}'`);
  check("the AI's login cannot edit the approvals table", selfUpd?.code === "42501", selfUpd?.message ?? "no error");
  await admin.query(`SELECT kit_approve($1, 'e2e-owner')`, [code]);   // what ./kit approve does
  const a3 = await W.call("archive_record", { table: t.name, id, reason: "e2e archive", approval_code: code });
  check("after approval: archive CONFIRMED", !a3.isError && a3.data.status === "CONFIRMED", a3.text);
  const arch = await one(`SELECT record, approval_code FROM archive WHERE source_table = $1 AND source_id = $2`, [t.sql_name, id]);
  check("record is gone from the table but kept whole in archive", !(await one(`SELECT id FROM "${t.sql_name}" WHERE id = $1`, [id])) && Number(arch?.record?.id) === id && arch?.approval_code === code);
  const a4 = await W.call("archive_record", { table: t.name, id, reason: "again", approval_code: code });
  check("an approval code works only once", a4.isError, a4.text);
  await rwPool.end();

  section("9. The receipt log is append-only (enforced by the database)");
  const up = await pgErr(admin, `UPDATE write_log SET actor = 'someone else' WHERE seq = 1`);
  check("even the ADMIN cannot UPDATE a receipt", !!up && /append-only/.test(up.message), up?.message ?? "no error");
  const dl = await pgErr(admin, `DELETE FROM write_log WHERE seq = 1`);
  check("even the ADMIN cannot DELETE a receipt", !!dl && /append-only/.test(dl.message), dl?.message ?? "no error");
  const tr = await pgErr(admin, `TRUNCATE access_log`);
  check("even the ADMIN cannot TRUNCATE the log", !!tr && /append-only/.test(tr.message), tr?.message ?? "no error");
  const rw2 = asRole(E.MCP_DB_USER, E.MCP_DB_PASSWORD);
  const fake = await pgErr(rw2, `INSERT INTO write_log (action, table_name, actor, prev_hash, hash) VALUES ('INSERT','x','fake','0','0')`);
  check("the AI's login cannot insert fake receipts", fake?.code === "42501", fake?.message ?? "no error");
  await rw2.end();

  section("10. verify_receipts");
  const v1 = await W.call("verify_receipts");
  check("chain intact and lock on", !v1.isError && v1.data.intact === true && /INTACT/.test(v1.text), v1.text);

  section("11. Tamper detection");
  await admin.query(`ALTER TABLE write_log DISABLE TRIGGER trg_write_log_no_change`);
  const v2 = await R.call("verify_receipts");
  check("switching the append-only lock off is reported", v2.data.intact === false && /lock: OFF/.test(v2.text), v2.text);
  const target = Number(created.write_log_seq);
  await admin.query(`UPDATE write_log SET new_value = jsonb_set(new_value, '{${updField.column}}', '"TAMPERED"') WHERE seq = $1`, [target]);
  await admin.query(`ALTER TABLE write_log ENABLE TRIGGER trg_write_log_no_change`);
  const v3 = await R.call("verify_receipts");
  const wl = (v3.data.chains ?? []).find((c: any) => c.chain === "write_log");
  check(`an edited receipt row is caught (BROKEN at #${target})`, v3.data.intact === false && wl?.intact === false && Number(wl?.first_bad_seq) === target && /BROKEN/.test(v3.text), v3.text);

  await W.close(); await R.close(); await admin.end();
  console.log(`\nRESULT: ${passed} passed, ${failed.length} failed`);
  if (failed.length) { console.log(`FAILED: ${failed.join(" | ")}`); process.exit(1); }
}
main().catch(async (e) => { console.error(`TEST CRASHED: ${e?.stack ?? e}`); process.exit(1); });
