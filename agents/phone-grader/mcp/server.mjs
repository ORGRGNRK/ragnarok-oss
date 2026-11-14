#!/usr/bin/env node
// PhoneGrader MCP server (stdio). Single source of truth: every tool shells out to
// `PhoneGrader --cli … --json`, so the app's own logic and history.json are reused.
// No delete tools. Atlas floor / max buy / deal breakdown / purchase / profit are returned
// under a `private` key: OK for the local AI to read, never for buyer-facing text.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import os from "node:os";
import path from "node:path";

const run = promisify(execFile);
export const BIN = process.env.PHONEGRADER_BIN || path.join(os.homedir(), "Applications/PhoneGrader.app/Contents/MacOS/PhoneGrader");

export async function pg(args) {
  try {
    const { stdout } = await run(BIN, ["--cli", ...args, "--json"], { env: process.env, timeout: 60_000, maxBuffer: 50e6 });
    return JSON.parse(stdout);
  } catch (e) {
    throw new Error(String(e.stderr || e.message || e).trim());
  }
}

export const PRIVATE_NOTE =
  "PRIVATE: Atlas floor prices, max buy, deal breakdown, purchase price and profit are for the owner only. " +
  "Never put them in Marketplace titles/descriptions, buyer messages, receipts or anything a buyer sees.";
const PRIVATE_KEYS = ["floor", "floorStatus", "floorQuotable", "maxBuy", "dealBreakdown", "flipKind"];

/** Move private fields under `private` so they are obvious. */
export function splitPrivate(rec) {
  const pub = { ...rec }, priv = {};
  for (const k of PRIVATE_KEYS) if (k in pub) { priv[k] = pub[k]; delete pub[k]; }
  if (pub.sale && "purchasePrice" in pub.sale) { pub.sale = { ...pub.sale }; priv.purchasePrice = pub.sale.purchasePrice; delete pub.sale.purchasePrice; }
  return { ...pub, private: { _note: PRIVATE_NOTE, ...priv } };
}

export function statusOf(r) {
  if (r.sale?.soldPrice != null) return "sold";
  if (r.sale?.listingPrice != null || r.askingPrice != null) return "listed";
  return "unlisted";
}

const ok = (obj) => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });
const wrap = (fn) => async (a) => {
  try { return ok(await fn(a)); } catch (e) { return { isError: true, content: [{ type: "text", text: e.message }] }; }
};
const id = z.number().int().positive().describe("History record id (#N)");
const at = z.string().optional().describe('When it happened: local "2026-10-16 19:30" or ISO 8601. Default now.');
const atArgs = (a) => (a ? ["--at", a] : []);

export function makeServer() {
  const s = new McpServer({ name: "phonegrader", version: "0.1.0" });

  s.tool("list_phones", "List phones in PhoneGrader history (newest first) with listing/sale status. Filters: status (listed = listed and not sold, sold, unsold = not sold yet, unlisted) and model text search.",
    { status: z.enum(["listed", "sold", "unsold", "unlisted"]).optional(), model: z.string().optional() },
    wrap(async ({ status, model }) => {
      const recs = await pg(["history", "list"]);
      const m = model?.toLowerCase();
      return recs.filter((r) => {
        const st = statusOf(r);
        if (status === "unsold" && st === "sold") return false;
        if (status && status !== "unsold" && st !== status) return false;
        if (m && !`${r.phoneModel} ${r.storageGb ?? ""}GB ${r.color ?? ""}`.toLowerCase().includes(m)) return false;
        return true;
      }).map((r) => ({
        id: r.id, createdAt: r.createdAt, model: r.phoneModel, storageGb: r.storageGb ?? null, color: r.color ?? null,
        carrierLock: r.carrierLock, grade: r.grade?.overall_grade ?? null, status: statusOf(r),
        listingPrice: r.sale?.listingPrice ?? r.askingPrice ?? null, listedAt: r.sale?.listedAt ?? null,
        soldPrice: r.sale?.soldPrice ?? null, soldAt: r.sale?.soldAt ?? null, notes: (r.notesLog ?? []).length,
      }));
    }));

  s.tool("get_phone", "Full record for one phone: grade, checklist/IMEI checks, repairs, listing text, sale tracking (days to sell, sold vs list %, actual profit), memory notes. Private price data is under `private`.",
    { id }, wrap(async ({ id }) => {
      const rec = await pg(["history", "show", String(id)]);
      const sale = await pg(["history", "sale", String(id)]);
      const out = splitPrivate(rec);
      out.saleComputed = { daysToSell: sale.daysToSell ?? null, soldVsListedPct: sale.soldVsListedPct ?? null };
      out.private.actualProfit = sale.actualProfit ?? null;
      return out;
    }));

  s.tool("business_stats", "Business summary: phones, sold/listed counts, avg days to sell, avg sold vs listed %, avg and total actual profit, revenue, purchase spend, parts spend. PRIVATE numbers.",
    {}, wrap(async () => {
      const [sales, parts] = await Promise.all([pg(["history", "sales"]), pg(["parts", "list"])]);
      return { ...sales, partsSpend: parts.total, partsPurchases: parts.count, _note: PRIVATE_NOTE };
    }));

  s.tool("set_listing_price", "Set or change a phone's Marketplace listing price (each change is kept with its date; first price sets listedAt).",
    { id, price: z.number().int().nonnegative(), at }, wrap(({ id, price, at: d }) => pg(["history", "set-listing", String(id), String(price), ...atArgs(d)])));
  s.tool("record_purchase_price", "Record what the owner actually paid for the phone (private; used for actual profit).",
    { id, price: z.number().nonnegative() }, wrap(({ id, price }) => pg(["history", "bought", String(id), String(price)])));
  s.tool("record_listing_stats", "Record Marketplace listing stats (clicks, saves, messages) with a checked-at timestamp.",
    { id, clicks: z.number().int().nonnegative(), saves: z.number().int().nonnegative(), messages: z.number().int().nonnegative(), at },
    wrap(({ id, clicks, saves, messages, at: d }) => pg(["history", "stats", String(id), String(clicks), String(saves), String(messages), ...atArgs(d)])));
  s.tool("mark_sold", "Mark a phone sold at a price (and date).",
    { id, price: z.number().int().nonnegative(), at }, wrap(({ id, price, at: d }) => pg(["history", "sold", String(id), String(price), ...atArgs(d)])));
  s.tool("mark_unsold", "Undo a sale (clears sold price/date; listing info kept).",
    { id }, wrap(({ id }) => pg(["history", "unsold", String(id)])));

  s.tool("add_phone_note", "Append a free-text memory note to a phone (append-only), e.g. 'buyer haggled from 650 to 600'.",
    { id, text: z.string().min(1), at }, wrap(({ id, text, at: d }) => pg(["history", "note", String(id), text, ...atArgs(d)])));
  s.tool("list_phone_notes", "Memory notes for one phone, oldest first.",
    { id }, wrap(({ id }) => pg(["history", "notes", String(id)])));
  s.tool("add_business_note", "Append a business-level memory note (append-only), e.g. supplier, pricing or buyer lessons.",
    { text: z.string().min(1), at }, wrap(({ text, at: d }) => pg(["notes", "add", text, ...atArgs(d)])));
  s.tool("list_business_notes", "The business-level notes log, oldest first.",
    {}, wrap(() => pg(["notes", "list"])));

  s.tool("parts_log_list", "Parts purchases (date, item, supplier, cost, linked phone) with total. Optional recordId filter.",
    { recordId: z.number().int().positive().optional() },
    wrap(({ recordId }) => pg(["parts", "list", ...(recordId ? ["--record", String(recordId)] : [])])));
  s.tool("parts_log_add", "Add a parts purchase to the Parts log (optionally linked to a phone; linked costs feed actual profit/max buy).",
    { item: z.string().min(1), cost: z.number().nonnegative(), supplier: z.string().optional(), recordId: z.number().int().positive().optional(),
      date: z.string().optional().describe("2026-10-16 (default today)"), note: z.string().optional() },
    wrap(({ item, cost, supplier, recordId, date, note }) => pg(["parts", "add", "--item", item, "--cost", String(cost),
      ...(supplier ? ["--supplier", supplier] : []), ...(recordId ? ["--record", String(recordId)] : []),
      ...(date ? ["--date", date] : []), ...(note ? ["--note", note] : [])])));
  return s;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("server.mjs")) {
  await makeServer().connect(new StdioServerTransport());
}
