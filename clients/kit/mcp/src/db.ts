// Postgres access: one small pool per scope. Write scope = the MCP read/write login (no DELETE
// anywhere, can't touch receipts). Read scope = the read-only login.
import pg from "pg";
import { dbConfig, type Scope } from "./config.js";

pg.types.setTypeParser(1082, (v: string) => v);          // date stays "YYYY-MM-DD"
pg.types.setTypeParser(20, (v: string) => Number(v));     // bigint ids -> numbers

const pools: Partial<Record<Scope, pg.Pool>> = {};
export function pool(scope: Scope): pg.Pool {
  let p = pools[scope];
  if (!p) {
    p = new pg.Pool({ ...dbConfig(scope), max: 4, connectionTimeoutMillis: 5000, idleTimeoutMillis: 10000 });
    p.on("error", (e) => console.error(`[client-kit] idle db client error: ${scrub(e)}`));
    pools[scope] = p;
  }
  return p;
}
export async function closeDb() { await Promise.all(Object.values(pools).map((p) => p?.end().catch(() => undefined))); }

/** Error text with anything password- or token-like removed. Used for every message and log line. */
export function scrub(e: unknown): string {
  const s = e instanceof Error ? e.message : String(e);
  return s
    .replace(/(postgres(?:ql)?:\/\/[^:\s/]+):[^@\s]+@/g, "$1:***@")
    .replace(/password=\S+/gi, "password=***")
    .replace(/Bearer\s+\S+/gi, "Bearer ***");
}
