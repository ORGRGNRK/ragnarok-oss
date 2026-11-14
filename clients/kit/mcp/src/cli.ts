#!/usr/bin/env node
// Helper used by ./kit (never by the AI):
//   node dist/src/cli.js check        validate client/schema.json and client/seed.json
//   node dist/src/cli.js schema-sql   print the SQL that creates the client's tables + grants
//   node dist/src/cli.js seed-sql     print the SQL that loads client/seed.json into empty tables
//   node dist/src/cli.js insert-sql   print the SQL that adds the rows of a JSON file on stdin (./kit money load);
//                                     rows whose unique key is already there are skipped
import { readFileSync } from "node:fs";
import { env } from "./config.js";
import { insertSql, loadSchema, schemaSql, seedSql } from "./schema.js";

const cmd = process.argv[2];
try {
  const s = loadSchema();
  const seedPath = env().KIT_SEED || "client/seed.json";
  const seed = () => JSON.parse(readFileSync(seedPath, "utf8"));
  if (cmd === "check") {
    seedSql(s, seed());
    console.log(`ok: ${s.client} -- ${s.tables.map((t) => `${t.name} (${t.fields.length} fields)`).join(", ")}`);
  } else if (cmd === "schema-sql") {
    const e = env();
    if (!e.MCP_DB_USER || !e.MCP_RO_DB_USER || !e.UI_DB_USER) throw new Error("MCP_DB_USER, MCP_RO_DB_USER and UI_DB_USER must be set");
    process.stdout.write("SET client_min_messages = warning;\n" + schemaSql(s, { rw: e.MCP_DB_USER, ro: e.MCP_RO_DB_USER, ui: e.UI_DB_USER }));
  } else if (cmd === "seed-sql") {
    process.stdout.write("SET client_min_messages = warning;\n" + seedSql(s, seed()));
  } else if (cmd === "insert-sql") {
    const data = JSON.parse(readFileSync(0, "utf8"));
    process.stdout.write("SET client_min_messages = warning;\n" + insertSql(s, data, process.argv[3] || "money import"));
  } else {
    console.error("usage: cli.js check | schema-sql | seed-sql | insert-sql [actor]"); process.exit(2);
  }
} catch (e) {
  console.error(`ERROR: ${(e as Error).message}`); process.exit(1);
}
