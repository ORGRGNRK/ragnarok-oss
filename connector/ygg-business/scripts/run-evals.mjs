#!/usr/bin/env node
// Read-only eval check, no LLM involved.
//   ./scripts/scratch-env.sh node scripts/run-evals.mjs
// For each <qa_pair> in evals/business-evals.xml:
//   (1) runs the matching SELECT from evals/answer-key.tsv as ygg_read in a READ ONLY transaction;
//   (2) derives the same answer through the MCP tools, by spawning dist/index.js over stdio.
// Exit 0 only if all 10 answers match both ways. Prints answers only, never connection strings.
//   --agree  (packaged / empty / demo installs) pass when the SQL answer key and the tools agree with
//            each other, ignoring the expected answers, which belong to the owner's real data.
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import pg from "pg";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const xml = await readFile(join(root, "evals/business-evals.xml"), "utf8");
const expected = [...xml.matchAll(/<answer>([\s\S]*?)<\/answer>/g)].map((m) => m[1].trim());
const key = (await readFile(join(root, "evals/answer-key.tsv"), "utf8"))
  .split("\n").filter(Boolean).map((l) => l.split("\t"));
if (expected.length !== 10 || key.length !== 10) { console.error(`expected 10 evals, got xml=${expected.length} key=${key.length}`); process.exit(2); }
const agree = process.argv.includes("--agree");
const url = process.env.BUSINESS_READ_DATABASE_URL;
if (!url) { console.error("run through ./scripts/scratch-env.sh (or inside the packaged container)"); process.exit(2); }

const norm = (v) => { if (v === null || v === undefined) return ""; const n = Number(v); return Number.isFinite(n) && String(v).trim() !== "" ? String(Math.round(n * 100) / 100) : String(v).trim(); };

// (1) SQL answer key, read-only
const sqlAns = [];
const c = new pg.Client({ connectionString: url, application_name: "ygg-mcp-business:evals" });
await c.connect();
try {
  await c.query("begin read only");
  for (const [, , sql] of key) { const r = await c.query(sql); sqlAns.push(Object.values(r.rows[0] ?? {})[0]); }
  await c.query("rollback");
} finally { await c.end(); }

// (2) through the MCP tools over stdio
const transport = new StdioClientTransport({ command: process.execPath, args: [join(root, "dist/index.js")], env: { ...process.env }, stderr: "ignore" });
const mcp = new Client({ name: "ygg-business-evals", version: "0.1.0" });
await mcp.connect(transport);
const call = async (name, args) => { const r = await mcp.callTool({ name, arguments: args }); if (r.isError) throw new Error(`${name}: ${r.content?.[0]?.text}`); return r.structuredContent; };
const all = []; let cursor;
do { const p = await call("business_list_items", { limit: 100, ...(cursor ? { cursor } : {}) }); all.push(...p.items); cursor = p.next_cursor; } while (cursor);
const top = (rows, f) => rows.filter((r) => r[f] !== null).sort((a, b) => b[f] - a[f])[0] ?? {};
const byStatus = await call("business_summarize_items", { group_by: "status" });
const byCat = await call("business_summarize_items", { group_by: "category" });
const gaming = await call("business_summarize_items", { group_by: "status", category: "Gaming" });
const active = await call("business_list_items", { limit: 100, status: "Active", category: "Pokemon" });
const max = (g, f) => [...g.groups].sort((a, b) => b[f] - a[f])[0]?.key;
const toolAns = [
  byStatus.groups.find((g) => g.key === "Sold")?.count ?? 0,
  top(all, "sold_price").uid,
  max(byCat, "realized_net_profit"),
  byCat.groups.find((g) => g.key === "Phone")?.realized_net_profit,
  active.count,
  all.filter((i) => i.category === "Phone" && i.sold_date && i.sold_date >= "2026-04-01" && i.sold_date < "2026-05-01").length,
  top(all, "parts_invested").uid,
  all.filter((i) => i.status === "Listed").map((i) => i.uid).sort().join(","),
  max(gaming, "count"),
  byCat.totals.realized_net_profit,
];
const tools = (await mcp.listTools()).tools.map((t) => t.name);
await mcp.close();

let pass = 0;
expected.forEach((exp, i) => {
  const ok = agree ? norm(sqlAns[i]) === norm(toolAns[i]) : norm(sqlAns[i]) === norm(exp) && norm(toolAns[i]) === norm(exp);
  if (ok) pass++;
  console.log(`${ok ? "PASS" : "FAIL"} Q${i + 1}: ${agree ? "" : `expected=${exp} `}sql=${norm(sqlAns[i])} tools=${norm(toolAns[i])}`);
});
console.log(`tools listed (${tools.length}): ${tools.join(", ")}`);
console.log(`${pass}/10 evals ${agree ? "agree (SQL answer key vs tools)" : "passed"} (items paged via tools: ${all.length})`);
process.exit(pass === 10 ? 0 : 1);
