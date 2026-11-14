#!/usr/bin/env node
/**
 * Generic migration runner: applies sql/*.sql to schema mcp using the owner URL.
 */
import { resolve } from "node:path";
import { createPool } from "../core/db.js";
import { applySqlDir } from "../core/migrate.js";
import { createRedactor, passwordFromUrl } from "../core/redact.js";
import { loadPlatformConfig } from "./config.js";

async function main() {
  const cfg = loadPlatformConfig();
  const redactor = createRedactor([passwordFromUrl(cfg.ownerUrl)]);
  const pool = createPool({
    connectionString: cfg.ownerUrl,
    applicationName: "secure-mcp-platform:migrate",
    statementTimeoutMs: cfg.statementTimeoutMs,
  });
  const sqlDir = resolve(new URL(".", import.meta.url).pathname, "../../sql");
  try {
    const applied = await applySqlDir(pool, sqlDir);
    process.stderr.write(`[platform:migrate] applied ${applied.length} file(s)\n`);
  } catch (err) {
    process.stderr.write(`[platform:migrate] error: ${redactor.text((err as Error).message)}\n`);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

main();
