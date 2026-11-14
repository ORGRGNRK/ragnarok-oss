/**
 * Tools for the generic Docker MCP platform.
 * Exposes inventory, leads, channels, search, and the hardware security lock controls.
 */
import { decodeCursor, encodeCursor } from "../core/cursor.js";
import type { Pool } from "../core/db.js";
import { ToolError } from "../core/errors.js";
import type { Embedder } from "../core/search/embedder.js";
import { VectorIndex } from "../core/search/vector-index.js";
import { SecurityGate } from "../core/security/gate.js";
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
  .describe("Opaque next_cursor from a previous call with same filters. Omit for first page.");
const filterText = (what: string) => z.string().trim().min(1).max(80).optional().describe(`${what} filter, exact match, case-insensitive.`);

function scopeOf(tool: string, filters: Record<string, unknown>): string {
  const parts = Object.entries(filters)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${String(v).toLowerCase()}`);
  return [tool, ...parts].join("|");
}

function page(scope: string, rows: q.Row[], more: boolean) {
  const last = rows[rows.length - 1];
  return {
    items: rows,
    count: rows.length,
    next_cursor: more && last ? encodeCursor(scope, Number(last.id)) : null,
  };
}

const money = (n: unknown) => (typeof n === "number" ? `$${n.toFixed(2).replace(/\.00$/, "")}` : "n/a");

interface SummaryTotals {
  count: number;
  total_cost_basis: number;
  total_revenue: number;
  realized_net_profit: number;
}

export interface PlatformToolDeps {
  readPool: Pool;
  appPool: Pool;
  embedder: Embedder;
  securityGate: SecurityGate;
  searchTimeoutMs: number;
}

export function platformTools(deps: PlatformToolDeps): ToolDef[] {
  const { readPool, securityGate } = deps;

  // 1. Platform Status (always allowed)
  const platformStatus = defineTool({
    name: "platform_status",
    title: "Check platform lock and operational status",
    description: "Returns the platform security gate lock status (locked or unlocked), session lease expiry, and operational health.",
    input: z.object({}).strict(),
    allowWhileLocked: true,
    annotations: READ_ONLY,
    async handler() {
      const st = securityGate.getStatus();
      return {
        summary: st.locked
          ? "Docker platform is LOCKED. Physical hardware authorization required (YubiKey / Secure Enclave)."
          : `Docker platform is UNLOCKED via ${st.method} (${st.remainingMinutes}m remaining).`,
        data: {
          platform: "secure-mcp-platform",
          status: st.locked ? "locked" : "unlocked",
          security_gate: st,
        },
      };
    },
  });

  // 2. Platform Unlock (always allowed)
  const platformUnlock = defineTool({
    name: "platform_unlock",
    title: "Unlock platform with hardware presence token",
    description: "Unlocks the Docker platform using a physical hardware assertion (YubiKey touch or Apple Secure Enclave biometric).",
    input: z
      .object({
        method: z.enum(["yubikey", "secure_enclave"]).describe("Authentication method used: 'yubikey' (FIDO2) or 'secure_enclave' (Touch ID)"),
        token: z.string().optional().describe("Signed hardware assertion or cryptographic challenge token from ./unlock.sh or companion app"),
      })
      .strict(),
    allowWhileLocked: true,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async handler(args) {
      try {
        const result = securityGate.unlock(args.method, args.token);
        return {
          summary: `Platform successfully UNLOCKED via ${args.method}. Valid until ${result.expiresAt.toISOString()}.`,
          data: {
            status: "unlocked",
            method: args.method,
            expires_at: result.expiresAt.toISOString(),
          },
        };
      } catch {
        throw new ToolError({
          code: "permission_denied",
          what: "platform_unlock rejected",
          why: "Invalid hardware authorization secret or proof token. Physical touch presence verification required.",
          retry_safe: false,
          fix: "Run ./unlock.sh from the host to verify physical hardware presence (Touch ID or YubiKey).",
        });
      }
    },
  });

  // 3. Platform Lock (always allowed)
  const platformLock = defineTool({
    name: "platform_lock",
    title: "Immediately lock/seal the Docker platform",
    description: "Immediately seals the Docker MCP platform, blocking any further database queries until re-authorized by physical hardware.",
    input: z.object({}).strict(),
    allowWhileLocked: true,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async handler() {
      securityGate.lock();
      return {
        summary: "Platform is now LOCKED. Hardware presence required to resume.",
        data: {
          status: "locked",
        },
      };
    },
  });

  // 4. List Items
  const listItems = defineTool({
    name: "platform_list_items",
    title: "List inventory items",
    description: "List platform inventory items with optional status and category filters. Keyset paginated.",
    input: z
      .object({
        limit: limit(20, 100),
        cursor,
        status: filterText("Status (e.g. active, sold, reserved, archived)"),
        category: filterText("Category filter"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(args) {
      const scope = scopeOf("platform_list_items", { status: args.status, category: args.category });
      const afterId = args.cursor ? decodeCursor("platform_list_items rejected cursor", args.cursor, scope) : 0;
      const { rows, more } = await q.listItems(readPool, { status: args.status, category: args.category }, afterId, args.limit);
      const res = page(scope, rows, more);
      return {
        summary: `Found ${res.count} item(s)${res.next_cursor ? " (more available)" : ""}`,
        data: res,
      };
    },
  });

  // 5. Get Item
  const getItem = defineTool({
    name: "platform_get_item",
    title: "Get item details",
    description: "Look up one inventory item by either integer id or unique string sku.",
    input: z
      .object({
        id: z.number().int().min(1).optional().describe("Item ID"),
        sku: z.string().trim().min(1).optional().describe("Item unique SKU"),
      })
      .strict()
      .refine((data) => (data.id !== undefined) !== (data.sku !== undefined), {
        message: "Pass exactly one of 'id' or 'sku'",
      }),
    annotations: READ_ONLY,
    async handler(args) {
      const item = await q.getItem(readPool, args);
      if (!item) {
        throw new ToolError({
          code: "not_found",
          what: "Item not found",
          why: `No item found matching ${args.id !== undefined ? `id=${args.id}` : `sku=${args.sku}`}`,
          retry_safe: false,
          fix: "Check the id or sku and try again.",
        });
      }
      return {
        summary: `Item ${item.id} (${item.sku}): ${item.name} [${item.status}] - Total cost: ${money(item.total_cost_basis)}`,
        data: { item },
      };
    },
  });

  // 6. Summarize Items
  const summarizeItems = defineTool({
    name: "platform_summarize_items",
    title: "Summarize inventory items by group",
    description: "Aggregates inventory counts, cost basis, revenue, and realized profit grouped by a column (status, category, platform, condition).",
    input: z
      .object({
        group_by: z.enum(["status", "category", "platform", "condition"]).describe("Column to group results by"),
        status: filterText("Status filter"),
        category: filterText("Category filter"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(args) {
      const groups = await q.summarizeItems(readPool, args.group_by, { status: args.status, category: args.category });
      const totals: SummaryTotals = groups.reduce(
        (acc: SummaryTotals, g) => ({
          count: acc.count + Number(g.count || 0),
          total_cost_basis: acc.total_cost_basis + Number(g.total_cost_basis || 0),
          total_revenue: acc.total_revenue + Number(g.total_revenue || 0),
          realized_net_profit: acc.realized_net_profit + Number(g.realized_net_profit || 0),
        }),
        { count: 0, total_cost_basis: 0, total_revenue: 0, realized_net_profit: 0 },
      );
      return {
        summary: `Summarized ${totals.count} item(s) across ${groups.length} ${args.group_by} group(s). Realized profit: ${money(totals.realized_net_profit)}`,
        data: {
          group_by: args.group_by,
          groups,
          totals,
        },
      };
    },
  });

  // 7. List Leads
  const listLeads = defineTool({
    name: "platform_list_leads",
    title: "List sales and acquisition leads",
    description: "Page through leads with optional stage filter.",
    input: z
      .object({
        limit: limit(20, 100),
        cursor,
        stage: filterText("Pipeline stage filter (e.g. new, qualified, won, lost)"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(args) {
      const scope = scopeOf("platform_list_leads", { stage: args.stage });
      const afterId = args.cursor ? decodeCursor("platform_list_leads rejected cursor", args.cursor, scope) : 0;
      const { rows, more } = await q.listLeads(readPool, args.stage, afterId, args.limit);
      const res = page(scope, rows, more);
      return {
        summary: `Found ${res.count} lead(s)${res.next_cursor ? " (more available)" : ""}`,
        data: res,
      };
    },
  });

  // 8. List Channels
  const listChannels = defineTool({
    name: "platform_list_channels",
    title: "List sales channels / exit routes",
    description: "Page through sales channels and partner outlets with optional active_only filter.",
    input: z
      .object({
        limit: limit(20, 100),
        cursor,
        active_only: z.boolean().default(false).describe("If true, list only active channels"),
      })
      .strict(),
    annotations: READ_ONLY,
    async handler(args) {
      const scope = scopeOf("platform_list_channels", { active_only: args.active_only });
      const afterId = args.cursor ? decodeCursor("platform_list_channels rejected cursor", args.cursor, scope) : 0;
      const { rows, more } = await q.listChannels(readPool, args.active_only, afterId, args.limit);
      const res = page(scope, rows, more);
      return {
        summary: `Found ${res.count} channel(s)${res.next_cursor ? " (more available)" : ""}`,
        data: res,
      };
    },
  });

  // 9. Semantic Search
  const searchIndex = new VectorIndex(deps.appPool, deps.embedder, q.itemIndexSource(readPool));
  const searchItems = defineTool({
    name: "platform_search_items",
    title: "Semantic search across inventory items",
    description: "Searches inventory using vector embeddings. Incremental sync occurs transparently.",
    input: z
      .object({
        query: z.string().trim().min(1).max(200).describe("Search phrase or query"),
        limit: limit(5, 25),
      })
      .strict(),
    timeoutMs: deps.searchTimeoutMs,
    annotations: READ_ONLY,
    async handler(args, { signal }) {
      const [qv] = await deps.embedder.embed([args.query], "query", signal);
      const stats = await searchIndex.sync(signal);
      const ranked = await searchIndex.rank(qv as number[], args.limit);
      const rows = await q.itemsByIds(readPool, ranked.map((r) => r.item_id));
      const byId = new Map(rows.map((r) => [Number(r.id), r]));
      const items = ranked
        .filter((r) => byId.has(r.item_id))
        .map((r) => ({ ...byId.get(r.item_id), score: Math.round(r.score * 10_000) / 10_000 }));

      return {
        summary: `Found ${items.length} item(s) matching "${args.query}"`,
        data: {
          query: args.query,
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

  return [
    platformStatus,
    platformUnlock,
    platformLock,
    listItems,
    getItem,
    summarizeItems,
    listLeads,
    listChannels,
    searchItems,
  ];
}
