/**
 * Wires the Business layer onto the shared core. Everything stateful (pools, limiter, embedder,
 * receipt sink) is passed in, so tests can build an isolated host.
 *
 * In the connector there is ONE business runtime per process (pools + rate limiter shared by
 * every connection); who is calling is carried per call in core/receipts.ts `callerContext`.
 */
import { createPool, type Pool } from "../core/db.js";
import { TokenBucket } from "../core/rate-limit.js";
import { AccessLogReceiptWriter, type ReceiptSink } from "../core/receipts.js";
import { createRedactor, type Redactor } from "../core/redact.js";
import { OllamaEmbedder, type Embedder } from "../core/search/embedder.js";
import { ToolHost } from "../core/server.js";
import type { BusinessConfig } from "./config.js";
import { businessTools } from "./tools.js";

export const SERVER_NAME = "ragnarok-connector";
export const SERVER_VERSION = "1.0.0";

export interface BusinessHostDeps {
  readPool: Pool;
  appPool: Pool;
  embedder: Embedder;
  limiter: TokenBucket;
  receipts: ReceiptSink;
  redactor: Redactor;
  toolTimeoutMs: number;
  searchTimeoutMs: number;
  log?: (msg: string) => void;
  attachReceipt?: boolean;
}

export const BUSINESS_INSTRUCTIONS =
  "Business tools are read-only views of the owner's flipping inventory: business_summarize_items for totals, " +
  "business_list_items to page through items, business_get_item for one item, business_search_items for fuzzy lookups, " +
  "business_list_leads and business_list_exit_profiles.";

export function createBusinessHost(d: BusinessHostDeps): ToolHost {
  return new ToolHost({
    name: SERVER_NAME,
    version: SERVER_VERSION,
    tools: businessTools(d),
    limiter: d.limiter,
    receipts: d.receipts,
    redactor: d.redactor,
    defaultTimeoutMs: d.toolTimeoutMs,
    ...(d.log ? { log: d.log } : {}),
    ...(d.attachReceipt ? { attachReceipt: true } : {}),
    instructions: BUSINESS_INSTRUCTIONS,
  });
}

export interface DbLogin { host: string; port: number; database: string; user: string; password: string }

const url = (l: DbLogin) =>
  `postgresql://${encodeURIComponent(l.user)}:${encodeURIComponent(l.password)}@${l.host}:${l.port}/${encodeURIComponent(l.database)}`;

/**
 * Production wiring. `read` = the data layer's read-only login (business reads, session forced
 * read-only). `app` = the read/write login, used only for the search cache (mcp schema) and the
 * access_log receipts; when it isn't configured the read-only login is used (search then can't
 * cache and says so).
 */
export function createBusinessRuntime(cfg: BusinessConfig, read: DbLogin, app: DbLogin | undefined, log: (msg: string) => void) {
  const redactor = createRedactor([read.password, app?.password]);
  const readPool = createPool({ connectionString: url(read), applicationName: "ragnarok-connector:business-read", statementTimeoutMs: cfg.statementTimeoutMs, readOnly: true });
  const appPool = createPool({ connectionString: url(app ?? read), applicationName: "ragnarok-connector:business-cache", statementTimeoutMs: cfg.statementTimeoutMs, max: 2 });
  const host = createBusinessHost({
    readPool,
    appPool,
    embedder: new OllamaEmbedder({ baseUrl: cfg.embedderUrl, model: cfg.embedderModel, timeoutMs: cfg.embedderTimeoutMs }),
    limiter: new TokenBucket({ capacity: cfg.rateCapacity, refillPerSecond: cfg.rateRefillPerSecond }),
    receipts: new AccessLogReceiptWriter(appPool, redactor, { onError: log }),
    redactor,
    toolTimeoutMs: cfg.toolTimeoutMs,
    searchTimeoutMs: cfg.searchTimeoutMs,
    log,
    attachReceipt: true,
  });
  return {
    host,
    redactor,
    readPool,
    appPool,
    async close() {
      await host.drain(5_000);
      await Promise.allSettled([readPool.end(), appPool.end()]);
    },
  };
}
