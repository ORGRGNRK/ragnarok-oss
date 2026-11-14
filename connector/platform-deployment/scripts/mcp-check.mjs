#!/usr/bin/env node
// Post-install check, no LLM: MCP handshake + tools/list over stdio (spawns dist/index.js) and,
// unless --stdio-only, over Streamable HTTP (MCP_HTTP_URL, default http://127.0.0.1:8787/mcp).
// Prints tool names and a count only; never connection strings. Exit 0 only if every transport
// lists exactly the 6 expected tools.
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readFileSync, existsSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const EXPECTED = [
  "platform_get_item",
  "platform_list_channels",
  "platform_list_items",
  "platform_list_leads",
  "platform_lock",
  "platform_search_items",
  "platform_status",
  "platform_summarize_items",
  "platform_unlock",
];
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const stdioOnly = process.argv.includes("--stdio-only");
const httpOnly = process.argv.includes("--http-only");
let failed = false;

let defaultPort = process.env.PLATFORM_MCP_HTTP_PORT;
if (!defaultPort && existsSync(join(root, ".env"))) {
  const m = readFileSync(join(root, ".env"), "utf8").match(/^PLATFORM_MCP_HTTP_PORT=(\d+)/m);
  if (m) defaultPort = m[1];
}
const httpUrl = process.env.MCP_HTTP_URL || `http://127.0.0.1:${defaultPort || "8787"}/mcp`;

async function check(label, transport) {
  const c = new Client({ name: "secure-mcp-platform-check", version: "0.2.0" });
  try {
    await c.connect(transport);
    const names = (await c.listTools()).tools.map((t) => t.name).sort();
    const status = await c.callTool({ name: "platform_status", arguments: {} });
    const ok = JSON.stringify(names) === JSON.stringify(EXPECTED) && !status.isError;
    console.log(`${ok ? "OK" : "FAIL"} ${label}: server=${c.getServerVersion()?.name} tools(${names.length})=${names.join(",")} status=${status.structuredContent?.status ?? "?"}`);
    if (!ok) failed = true;
  } catch (e) {
    console.log(`FAIL ${label}: ${e.message}`);
    failed = true;
  } finally {
    await c.close().catch(() => {});
  }
}

if (!httpOnly) {
  await check("stdio", new StdioClientTransport({ command: process.execPath, args: [join(root, "dist/index.js")], env: { ...process.env }, stderr: "ignore" }));
}
if (!stdioOnly) {
  await check("http", new StreamableHTTPClientTransport(new URL(httpUrl)));
}
process.exit(failed ? 1 : 0);
