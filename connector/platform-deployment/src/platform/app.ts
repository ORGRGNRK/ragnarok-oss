/**
 * Wires the generic platform layer with security gating and core MCP infrastructure.
 */
import { createPool, type Pool } from "../core/db.js";
import { TokenBucket } from "../core/rate-limit.js";
import { PgReceiptWriter, type ReceiptSink } from "../core/receipts.js";
import { createRedactor, passwordFromUrl, type Redactor } from "../core/redact.js";
import { OllamaEmbedder, type Embedder } from "../core/search/embedder.js";
import { SecurityGate } from "../core/security/gate.js";
import { ToolHost } from "../core/server.js";
import type { PlatformConfig } from "./config.js";
import { platformTools } from "./tools.js";

export const SERVER_NAME = "secure-mcp-platform";
export const SERVER_VERSION = "0.2.0";

export interface PlatformHostDeps {
  readPool: Pool;
  appPool: Pool;
  embedder: Embedder;
  limiter: TokenBucket;
  receipts: ReceiptSink;
  redactor: Redactor;
  securityGate: SecurityGate;
  toolTimeoutMs: number;
  searchTimeoutMs: number;
  log?: (msg: string) => void;
}

export function createPlatformHost(d: PlatformHostDeps): ToolHost {
  return new ToolHost({
    name: SERVER_NAME,
    version: SERVER_VERSION,
    tools: platformTools(d),
    limiter: d.limiter,
    receipts: d.receipts,
    redactor: d.redactor,
    securityGate: d.securityGate,
    defaultTimeoutMs: d.toolTimeoutMs,
    ...(d.log ? { log: d.log } : {}),
    instructions:
      "Secure Docker MCP platform for PostgreSQL items, leads, and channels. " +
      "Default state is boot-locked until hardware presence authorization (YubiKey or Apple Secure Enclave) is confirmed. " +
      "Use platform_status to check lock state and platform_unlock to authenticate.",
  });
}

export function createPlatformRuntime(cfg: PlatformConfig, log: (msg: string) => void) {
  const redactor = createRedactor([passwordFromUrl(cfg.readUrl), passwordFromUrl(cfg.ownerUrl)]);
  const readPool = createPool({
    connectionString: cfg.readUrl,
    applicationName: "secure-mcp-platform:read",
    statementTimeoutMs: cfg.statementTimeoutMs,
    readOnly: true,
  });
  const appPool = createPool({
    connectionString: cfg.ownerUrl,
    applicationName: "secure-mcp-platform:owner",
    statementTimeoutMs: cfg.statementTimeoutMs,
    max: 2,
  });
  const securityGate = new SecurityGate({
    requireAuth: cfg.requireAuth,
    sessionTtlMinutes: cfg.sessionTtlMinutes,
    unlockSecret: cfg.unlockSecret,
  });

  const host = createPlatformHost({
    readPool,
    appPool,
    embedder: new OllamaEmbedder({ baseUrl: cfg.embedderUrl, model: cfg.embedderModel, timeoutMs: cfg.embedderTimeoutMs }),
    limiter: new TokenBucket({ capacity: cfg.rateCapacity, refillPerSecond: cfg.rateRefillPerSecond }),
    receipts: new PgReceiptWriter(appPool, redactor, { onError: log }),
    redactor,
    securityGate,
    toolTimeoutMs: cfg.toolTimeoutMs,
    searchTimeoutMs: cfg.searchTimeoutMs,
    log,
  });

  return {
    host,
    readPool,
    appPool,
    redactor,
    securityGate,
    async close() {
      await Promise.allSettled([readPool.end(), appPool.end()]);
    },
  };
}
