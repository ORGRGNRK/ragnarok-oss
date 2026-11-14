#!/usr/bin/env node
// Local transport: an AI app on this computer (Claude Desktop, Claude Code) starts this and talks
// to it over stdin/stdout. Nothing but MCP messages may go to stdout; logs go to stderr.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { serverScope, stdioIdentity } from "./config.js";
import { closeDb, scrub } from "./db.js";
import { loadSchema } from "./schema.js";
import { buildServer } from "./server.js";

async function main() {
  const scope = serverScope();
  const via = stdioIdentity();
  loadSchema();
  const server = buildServer(scope, via, `stdio-${new Date().toISOString().slice(0, 19).replace(/[:T-]/g, "")}-${process.pid}`);
  await server.connect(new StdioServerTransport());
  console.error(`[client-kit] stdio ready -- scope ${scope} -- ${via}`);
  const stop = async () => { await closeDb(); process.exit(0); };
  process.stdin.on("end", stop);
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
main().catch((e) => { console.error(`[client-kit] FATAL: ${scrub(e)}`); process.exit(1); });
