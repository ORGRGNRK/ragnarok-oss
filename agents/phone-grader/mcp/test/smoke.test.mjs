// Runs the real MCP server against a TEMP copy of history (PHONEGRADER_DATA_DIR); never touches real data.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const BIN = process.env.PHONEGRADER_BIN || path.join(repo, ".build/debug/PhoneGrader");
const realHistory = path.join(os.homedir(), "Library/Application Support/PhoneGrader/history.json");
let tmp, client, realBefore;

const fixture = [
  { id: 2, createdAt: "2026-10-16T19:00:00Z", phoneModel: "iPhone 16 Pro", storageGb: 128, carrierLock: "unlocked", checklist: [],
    backend: "test", photoFiles: [], floor: 410, maxBuy: 330, grade: { overall_grade: "B", categories: [], concerns: [], photos_needed: [], summary: "" } },
  { id: 1, createdAt: "2026-10-10T19:00:00Z", phoneModel: "iPhone 13", storageGb: 128, carrierLock: "unlocked", checklist: [],
    backend: "test", photoFiles: [], notes: "legacy record" },
];
const call = async (name, args = {}) => {
  const r = await client.callTool({ name, arguments: args });
  assert.ok(!r.isError, `${name}: ${r.content?.[0]?.text}`);
  return JSON.parse(r.content[0].text);
};

before(async () => {
  assert.ok(fs.existsSync(BIN), `build first (swift build): ${BIN}`);
  realBefore = fs.existsSync(realHistory) ? fs.statSync(realHistory).mtimeMs : null;
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pg-mcp-"));
  fs.writeFileSync(path.join(tmp, "history.json"), JSON.stringify(fixture));
  client = new Client({ name: "smoke", version: "0" });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [path.join(here, "../server.mjs")],
    env: { ...process.env, PHONEGRADER_DATA_DIR: tmp, PHONEGRADER_BIN: BIN } }));
});
after(async () => { await client?.close(); fs.rmSync(tmp, { recursive: true, force: true }); });

test("tool list (no delete tools)", async () => {
  const names = (await client.listTools()).tools.map((t) => t.name).sort();
  for (const n of ["list_phones", "get_phone", "business_stats", "set_listing_price", "record_purchase_price", "record_listing_stats",
    "mark_sold", "mark_unsold", "add_phone_note", "add_business_note", "list_business_notes", "parts_log_list", "parts_log_add"]) assert.ok(names.includes(n), n);
  assert.ok(!names.some((n) => /delete|remove|trash/.test(n)));
});

test("sale flow, notes, stats, parts on temp data", async () => {
  assert.equal((await call("list_phones")).length, 2);
  await call("set_listing_price", { id: 2, price: 650, at: "2026-10-16 19:30" });
  await call("record_purchase_price", { id: 2, price: 330 });
  const st = await call("record_listing_stats", { id: 2, clicks: 12, saves: 0, messages: 0 });
  assert.equal(st.sale.clicks, 12);
  assert.deepEqual((await call("list_phones", { status: "listed" })).map((p) => p.id), [2]);
  assert.deepEqual((await call("list_phones", { model: "13" })).map((p) => p.id), [1]);
  await call("add_phone_note", { id: 2, text: "AT&T unlocked it" });
  await call("add_phone_note", { id: 2, text: "buyer haggled from 650 to 600" });
  await call("parts_log_add", { item: "Back glass", cost: 18.5, recordId: 2, date: "2026-10-15" });
  assert.equal((await call("parts_log_list", { recordId: 2 })).total, 18.5);
  await call("mark_sold", { id: 2, price: 600, at: "2026-10-20 18:00" });
  const p = await call("get_phone", { id: 2 });
  assert.equal(p.private.floor, 410); assert.equal(p.private.maxBuy, 330); assert.equal(p.private.purchasePrice, 330);
  assert.ok(!("floor" in p) && !("purchasePrice" in p.sale)); assert.match(p.private._note, /PRIVATE/);
  assert.equal(p.saleComputed.daysToSell, 4);
  assert.equal(p.saleComputed.soldVsListedPct.toFixed(1), "92.3");
  assert.equal(p.private.actualProfit, 270);           // no deal breakdown → parts/gas from breakdown = 0
  assert.deepEqual(p.notesLog.map((n) => n.text), ["AT&T unlocked it", "buyer haggled from 650 to 600"]);
  assert.deepEqual((await call("list_phones", { status: "sold" })).map((x) => x.id), [2]);
  await call("add_business_note", { text: "Local buyers respond best to evening listings" });
  assert.equal((await call("list_business_notes")).notes.length, 1);
  const s = await call("business_stats");
  assert.equal(s.sold, 1); assert.equal(s.totalRevenue, 600); assert.equal(s.partsSpend, 18.5); assert.equal(s.phones, 2);
  await call("mark_unsold", { id: 2 });
  assert.deepEqual((await call("list_phones", { status: "unsold" })).map((x) => x.id).sort(), [1, 2]);
  const legacy = await call("get_phone", { id: 1 });           // old record still loads
  assert.equal(legacy.notes, "legacy record");
});

test("bad input surfaces as tool error", async () => {
  const r = await client.callTool({ name: "get_phone", arguments: { id: 999 } });
  assert.ok(r.isError);
  const e = await client.callTool({ name: "set_listing_price", arguments: { id: 2, price: 1, at: "someday" } });
  assert.ok(e.isError);
});

test("real history untouched", () => {
  const now = fs.existsSync(realHistory) ? fs.statSync(realHistory).mtimeMs : null;
  assert.equal(now, realBefore);
});
