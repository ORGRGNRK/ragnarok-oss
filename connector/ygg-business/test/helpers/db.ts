import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createBusinessHost } from "../../src/business/app.js";
import { createPool, type Pool } from "../../src/core/db.js";
import { TokenBucket } from "../../src/core/rate-limit.js";
import { PgReceiptWriter } from "../../src/core/receipts.js";
import { createRedactor, passwordFromUrl } from "../../src/core/redact.js";
import type { Embedder } from "../../src/core/search/embedder.js";
import type { ToolHost } from "../../src/core/server.js";

export const READ_URL = process.env.BUSINESS_READ_DATABASE_URL;
export const APP_URL = process.env.BUSINESS_APP_DATABASE_URL;
export const hasDb = Boolean(READ_URL && APP_URL);
if (!hasDb) {
  console.warn("integration tests skipped: run through ./scripts/scratch-env.sh to provide BUSINESS_*_DATABASE_URL");
}

export interface Harness {
  readPool: Pool;
  appPool: Pool;
  host: ToolHost;
  client: Client;
  close(): Promise<void>;
}

/** A fully isolated host (own pools, limiter, embedder) connected to an in-memory MCP client. */
export async function startHarness(embedder: Embedder, opts: { capacity?: number; refillPerSecond?: number } = {}): Promise<Harness> {
  const redactor = createRedactor([passwordFromUrl(READ_URL), passwordFromUrl(APP_URL)]);
  const readPool = createPool({ connectionString: READ_URL as string, applicationName: "ygg-mcp-business:test", statementTimeoutMs: 5000, readOnly: true });
  const appPool = createPool({ connectionString: APP_URL as string, applicationName: "ygg-mcp-business:test", statementTimeoutMs: 5000 });
  const host = createBusinessHost({
    readPool,
    appPool,
    embedder,
    limiter: new TokenBucket({ capacity: opts.capacity ?? 1000, refillPerSecond: opts.refillPerSecond ?? 1000 }),
    receipts: new PgReceiptWriter(appPool, redactor),
    redactor,
    toolTimeoutMs: 10_000,
    searchTimeoutMs: 60_000,
  });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  const server = host.createServer();
  await server.connect(st);
  const client = new Client({ name: "vitest", version: "0" });
  await client.connect(ct);
  return {
    readPool,
    appPool,
    host,
    client,
    async close() {
      await client.close();
      await server.close();
      await Promise.allSettled([readPool.end(), appPool.end()]);
    },
  };
}

export type ToolResult = {
  isError?: boolean;
  content: Array<{ type: string; text?: string }>;
  structuredContent?: Record<string, any>;
};

export async function call(h: Harness, name: string, args: Record<string, unknown>): Promise<ToolResult> {
  return (await h.client.callTool({ name, arguments: args })) as ToolResult;
}
