#!/usr/bin/env node
/**
 * Entry point: Secure MCP Platform over stdio.
 * Boots in a locked state until unlocked by hardware presence (YubiKey or Apple Secure Enclave).
 * stdout carries only JSON-RPC; all logs go to stderr, redacted.
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createRedactor } from "./core/redact.js";
import { createPlatformRuntime } from "./platform/app.js";
import { loadPlatformConfig } from "./platform/config.js";

async function main(): Promise<void> {
  let log = (msg: string) => process.stderr.write(`[secure-mcp-platform] ${createRedactor().text(msg)}\n`);
  const cfg = loadPlatformConfig();
  const rt = createPlatformRuntime(cfg, (m) => log(m));
  log = (msg: string) => process.stderr.write(`[secure-mcp-platform] ${rt.redactor.text(msg)}\n`);

  const server = rt.host.createServer();
  let closing = false;
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    await rt.host.drain(cfg.searchTimeoutMs);
    await new Promise((r) => setImmediate(r));
    await server.close().catch(() => {});
    await rt.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.stdin.on("end", shutdown);

  await server.connect(new StdioServerTransport());
  log(`ready on stdio (locked=${rt.securityGate.isLocked()}, embedder ${cfg.embedderModel} at ${cfg.embedderUrl})`);
}

main().catch((err) => {
  process.stderr.write(`[secure-mcp-platform] fatal: ${createRedactor().text((err as Error).message)}\n`);
  process.exit(1);
});
