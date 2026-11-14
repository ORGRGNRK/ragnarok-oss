/**
 * The thin Business layer: six tools on top of the shared core.
 */
import { decodeCursor, encodeCursor } from "../core/cursor.js";
import type { Pool } from "../core/db.js";
import { spawnClientStack, SpawnClientSchema } from "./ragnarok_spawn_tool.js";
import { ToolError } from "../core/errors.js";
import type { Embedder } from "../core/search/embedder.js";
import { VectorIndex } from "../core/search/vector-index.js";
import { defineTool, type ToolDef } from "../core/server.js";
import { z } from "../core/validate.js";
import * as q from "./queries.js";

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } as const;

const limit = (dflt: number, max: number) =>
  z.number().int().min(1).max(max).default(dflt).describe(`Page size, 1-${max} (default ${dflt}).`);
const cursor = z
  .string()
  .min(1)
  .max(512)
  .optional()
  .describe("Opaque next_cursor from a previous call with the same filters. Omit for the first page.");
const filterText = (what: string) => z.string().trim().min(1).max(80).optional().describe(`${what} filter, exact match, case-insensitive.`);

function scopeOf(tool: string, filters: Record<string, unknown>): string {
  const parts = Object.entries(filters)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${String(v).toLowerCase()}`);
  return [tool, ...parts].join("|");
}

function page(tool: string, scope: string, rows: q.Row[], more: boolean) {
  const last = rows[rows.length - 1];
  return {
    items: rows,
    count: rows.length,
    next_cursor: more && last ? encodeCursor(scope, Number(last.id)) : null,
  };
}

const money = (n: unknown) => (typeof n === "number" ? `$${n.toFixed(2).replace(/\.00$/, "")}` : "n/a");

export interface BusinessToolDeps {
  readPool: Pool;
  appPool: Pool;
  embedder: Embedder;
  searchTimeoutMs: number;
}

export function businessTools(deps: BusinessToolDeps): ToolDef[] {
  const { readPool } = deps;

  const listItems = defineTool({
    name: "business_list_items",
    title: "List inventory items",
    description:
      "List Business inventory items (flipped devices, cards, parts) in id order with optional status/category filters. " +
      "Paginated: pass next_cursor back as cursor to get the next page; next_cursor is null on the last page. " +
      "Money fields come from the business_with_totals view (net_profit = sold - buy - parts; for unsold items it is minus the cost basis).",
    input: z
      .object({
        limit: limit(20, 100),
        cursor,
        status: filterText("Status (e.g. Sold, Active, Listed, Parked, Non-Liquid)"),
        category: filterText("Category (e.g. Phone, Gaming, Pokemon)"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(a) {
      const scope = scopeOf("list_items", { status: a.status, category: a.category });
      const after = a.cursor ? decodeCursor("business_list_items rejected the cursor", a.cursor, scope) : 0;
      const { rows, more } = await q.listItems(readPool, a, after, a.limit);
      const data = page("business_list_items", scope, rows, more);
      const span = rows.length ? ` (ids ${rows[0]?.id}-${rows[rows.length - 1]?.id})` : "";
      return {
        summary: `${rows.length} item(s)${span}${more ? "; more available, pass next_cursor" : "; last page"}.`,
        data,
      };
    },
  });

  const getItem = defineTool({
    name: "business_get_item",
    title: "Get one inventory item",
    description:
      "Get full details for one Business item by numeric id or by UID (e.g. INV-2026-013). Provide exactly one of id or uid. " +
      "IMEIs are returned as last-4 only.",
    input: z
      .object({
        id: z.number().int().min(1).optional().describe("Numeric item id."),
        uid: z.string().trim().min(1).max(40).optional().describe("Inventory UID, e.g. INV-2026-013."),
      })
      .strict()
      .refine((v) => (v.id === undefined) !== (v.uid === undefined), { message: "provide exactly one of id or uid" }),
    annotations: READ_ONLY,
    async handler(a) {
      const row = await q.getItem(readPool, a);
      const key = a.id !== undefined ? `id ${a.id}` : `uid ${a.uid}`;
      if (!row) {
        throw new ToolError({
          code: "not_found",
          what: `no Business item with ${key}`,
          why: "the id/uid does not exist in the Business table",
          retry_safe: false,
          fix: "find valid ids with business_list_items or business_search_items, then call again",
        });
      }
      return {
        summary: `${row.uid ?? `#${row.id}`}: ${row.item} (${row.status ?? "no status"}; bought ${money(row.buy_price)}, sold ${money(row.sold_price)}).`,
        data: { item: row },
      };
    },
  });

  const summarize = defineTool({
    name: "business_summarize_items",
    title: "Summarize inventory",
    description:
      "Count items and total buy price, parts, sold price and realized net profit (sold items only), grouped by status, category, platform or condition. " +
      "Optional status/category filters apply before grouping. Blank group values are reported as key null.",
    input: z
      .object({
        group_by: z.enum(["status", "category", "platform", "condition"]).describe("Column to group by."),
        status: filterText("Status"),
        category: filterText("Category"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(a) {
      const groups = await q.summarizeItems(readPool, a.group_by, a);
      const sum = (k: string) => Math.round(groups.reduce((s, g) => s + Number(g[k] ?? 0), 0) * 100) / 100;
      const totals = {
        count: sum("count"),
        buy_total: sum("buy_total"),
        parts_total: sum("parts_total"),
        sold_total: sum("sold_total"),
        realized_net_profit: sum("realized_net_profit"),
      };
      const top = groups[0];
      return {
        summary: `${totals.count} item(s) in ${groups.length} ${a.group_by} group(s)` +
          (top ? `; largest: ${top.key ?? "(blank)"} with ${top.count}` : "") +
          `; realized net profit ${money(totals.realized_net_profit)}.`,
        data: { group_by: a.group_by, groups, totals },
      };
    },
  });

  const listLeads = defineTool({
    name: "business_list_leads",
    title: "List purchase leads",
    description: "List purchase leads (devices offered to buy) in id order, optionally filtered by status. Paginated with next_cursor.",
    input: z.object({ limit: limit(20, 100), cursor, status: filterText("Lead status") }).strict(),
    annotations: READ_ONLY,
    async handler(a) {
      const scope = scopeOf("list_leads", { status: a.status });
      const after = a.cursor ? decodeCursor("business_list_leads rejected the cursor", a.cursor, scope) : 0;
      const { rows, more } = await q.listLeads(readPool, a.status, after, a.limit);
      return {
        summary: `${rows.length} lead(s)${more ? "; more available, pass next_cursor" : "; last page"}.`,
        data: page("business_list_leads", scope, rows, more),
      };
    },
  });

  const listExits = defineTool({
    name: "business_list_exit_profiles",
    title: "List exit profiles",
    description:
      "List exit profiles (buyers/channels to sell through, with grade floors and fees) in id order. " +
      "Set active_only to hide inactive ones. Paginated with next_cursor.",
    input: z
      .object({
        limit: limit(20, 100),
        cursor,
        active_only: z.boolean().default(false).describe("Only profiles marked Active."),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(a) {
      const scope = scopeOf("list_exit_profiles", { active_only: a.active_only });
      const after = a.cursor ? decodeCursor("business_list_exit_profiles rejected the cursor", a.cursor, scope) : 0;
      const { rows, more } = await q.listExitProfiles(readPool, a.active_only, after, a.limit);
      return {
        summary: `${rows.length} exit profile(s)${a.active_only ? " (active only)" : ""}${more ? "; more available, pass next_cursor" : "; last page"}.`,
        data: page("business_list_exit_profiles", scope, rows, more),
      };
    },
  });

  const index = new VectorIndex(deps.appPool, deps.embedder, q.itemIndexSource(readPool));

  const search = defineTool({
    name: "business_search_items",
    title: "Semantic search over items",
    description:
      "Semantic search over Business items by meaning (item name, category, status, condition, platform, notes). " +
      "Before ranking it embeds any items added or changed since the last search (lazy, incremental index), so the first call can be slow. " +
      "Needs the configured embedder (Ollama API); if it is down you get a retry-safe error. Only the mcp search cache is written.",
    input: z
      .object({
        query: z.string().trim().min(1).max(200).describe("What to look for, in plain words."),
        limit: limit(5, 25),
      })
      .strict(),
    annotations: READ_ONLY,
    timeoutMs: deps.searchTimeoutMs,
    async handler(a, { signal }) {
      // Embed the query first: if the embedder is down, fail fast before touching the index.
      const [qv] = await deps.embedder.embed([a.query], "query", signal);
      const stats = await index.sync(signal);
      const ranked = await index.rank(qv as number[], a.limit);
      const rows = await q.itemsByIds(readPool, ranked.map((r) => r.item_id));
      const byId = new Map(rows.map((r) => [Number(r.id), r]));
      const items = ranked
        .filter((r) => byId.has(r.item_id))
        .map((r) => ({ ...byId.get(r.item_id), score: Math.round(r.score * 10_000) / 10_000 }));
      const top = items[0] as q.Row | undefined;
      return {
        summary:
          `${items.length} match(es) for "${a.query}"` +
          (top ? `; best: ${top.uid ?? `#${top.id}`} ${top.item} (score ${top.score})` : "") +
          `; indexed ${stats.embedded} new/changed item(s) first.`,
        data: {
          query: a.query,
          items,
          count: items.length,
          index: {
            model: deps.embedder.model,
            embedded_now: stats.embedded,
            unchanged: stats.unchanged,
            storage: "postgres real[] fallback (pgvector not installed); cosine ranked in-process",
          },
        },
      };
    },
  });

  const diagnoseNetwork = defineTool({
    name: "business_get_network_diagnostics",
    title: "Diagnose Network & Transport",
    description:
      "Self-healing tool: inspects the cryptographic transport log for rejected HTTP requests, 401 token failures, or latency spikes.",
    input: z
      .object({
        limit: z.number().int().min(1).max(50).default(10).describe("Max rows to inspect (1-50, default 10)."),
        failures_only: z.boolean().default(true).describe("If true, only returns HTTP 4xx/5xx requests."),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(a) {
      const client = await readPool.connect();
      try {
        const where = a.failures_only ? "WHERE status_code >= 400" : "";
        const res = await client.query(
          `SELECT seq, client_ip, method, path, status_code, token_label, duration_ms, error_message, hash, created_at 
           FROM transport_log ${where} ORDER BY seq DESC LIMIT $1`,
          [a.limit],
        );
        const rows = res.rows as Array<{
          seq: number | string;
          client_ip: string;
          method: string;
          path: string;
          status_code: number;
          token_label: string | null;
          duration_ms: number;
          error_message: string | null;
          hash: string;
          created_at: string;
        }>;

        const report = rows
          .map(
            (r) =>
              `[HTTP #${r.seq}] ${r.status_code} ${r.method} ${r.path} from ${r.client_ip} (${r.duration_ms}ms)\n` +
              `  Token: ${r.token_label ?? "none"} | Error: ${r.error_message ?? "none"} | Hash: ${String(r.hash).slice(0, 16)}...`,
          )
          .join("\n\n");

        return {
          summary: rows.length
            ? `TRANSPORT TELEMETRY: ${rows.length} record(s) inspected.`
            : "All transport requests healthy (zero recent HTTP failures).",
          data: {
            failures_only: a.failures_only,
            count: rows.length,
            records: rows,
            report: rows.length ? report : "All transport requests healthy (zero recent HTTP failures).",
          },
        };
      } finally {
        client.release();
      }
    },
  });

  const spawnClient = defineTool({
    name: "ragnarok_get_client_stack",
    title: "Spawn a new client stack",
    description: [
      "Create a brand-new isolated client stack (Postgres + NocoDB + MCP) from a conversation.",
      "The agent defines the schema (tables + fields) and this tool provisions everything.",
      "Returns a receipt with connection details and a sealed hash chain entry.",
      "",
      "Ask the client these 4 questions first, THEN call this tool:",
      "  1. What should we call this project? (slug: lowercase, hyphens only)",
      "  2. What tables do you need? (e.g. Inventory, Customers, Orders)",
      "  3. What fields go in each table? (name + type: Text, Number, Currency, Date, SingleSelect...)",
      "  4. Any starter data to seed in?",
    ].join("\n"),
    input: SpawnClientSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    timeoutMs: 300_000,
    handler: async (args) => {
      const result = await spawnClientStack(args);
      return { summary: `Client stack spawned: ${args.client_slug}`, data: { output: result } };
    },
  });

  return [listItems, getItem, summarize, listLeads, listExits, search, diagnoseNetwork, spawnClient] as unknown as ToolDef[];
}
