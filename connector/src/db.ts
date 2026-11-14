// Postgres access: one small pool per scope. Write scope = the MCP read/write login (no DELETE
// anywhere, can't touch receipts). Read scope = the read-only login.
import pg from "pg";
import { dbConfig, env, type Scope } from "./config.js";
import { createRedactor, type Redactor } from "./core/redact.js";

pg.types.setTypeParser(1082, (v: string) => v);          // date stays "YYYY-MM-DD"
pg.types.setTypeParser(20, (v: string) => Number(v));     // bigint ids -> numbers

const pools: Partial<Record<Scope, pg.Pool>> = {};
export function pool(scope: Scope): pg.Pool {
  let p = pools[scope];
  if (!p) {
    p = new pg.Pool({ ...dbConfig(scope), max: 4, connectionTimeoutMillis: 5000, idleTimeoutMillis: 10000 });
    p.on("error", (e) => console.error(`[connector] idle db client error: ${scrub(e)}`));
    pools[scope] = p;
  }
  return p;
}
export async function closeDb() { await Promise.all(Object.values(pools).map((p) => p?.end().catch(() => undefined))); }

/** Error text with anything password- or token-like removed. Used for every message and log line.
 *  Uses the shared core redactor (URL credentials, key=value secrets, and the configured database
 *  passwords and tokens wherever they appear) plus "Bearer <token>". */
let redactor: Redactor | undefined;
export function scrub(e: unknown): string {
  const s = e instanceof Error ? e.message : String(e);
  if (!redactor) { const v = env(); redactor = createRedactor([v.MCP_DB_PASSWORD, v.MCP_RO_DB_PASSWORD, v.MCP_TOKEN, v.MCP_READ_TOKEN]); }
  return redactor.text(s).replace(/Bearer\s+\S+/gi, "Bearer ***");
}
