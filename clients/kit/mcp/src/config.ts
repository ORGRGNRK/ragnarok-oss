// Settings. Inside Docker they come from the container environment (docker-compose.yml passes
// them from .env). Run locally (MCP_LOCAL=1 ./kit mcp-stdio) they are read from the kit's .env.
import { existsSync, readFileSync } from "node:fs";
import { hostname, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type Scope = "read" | "write";

function readDotEnv(): Record<string, string> {
  const here = dirname(fileURLToPath(import.meta.url));
  for (const p of [join(here, "../../../.env"), join(process.cwd(), ".env")]) {
    if (!existsSync(p)) continue;
    const out: Record<string, string> = {};
    for (const line of readFileSync(p, "utf8").split(/\r?\n/)) {
      const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
      if (m && !line.trimStart().startsWith("#")) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
    return out;
  }
  return {};
}

let envCache: Record<string, string | undefined> | undefined;
/** Settings. A secret can arrive as a file instead of a variable: FOO_FILE=/run/secrets/foo sets FOO from
 *  that file (Docker secrets), so passwords and tokens don't show up in `docker inspect`. */
export function env(): Record<string, string | undefined> {
  if (!envCache) {
    const e: Record<string, string | undefined> = { ...readDotEnv(), ...process.env };
    for (const k of Object.keys(e)) {
      if (!k.endsWith("_FILE") || !e[k]) continue;
      const base = k.slice(0, -5);
      try { e[base] = readFileSync(e[k] as string, "utf8").replace(/\r?\n$/, ""); }
      catch { throw new Error(`${k} points at ${e[k]}, which can't be read`); }
    }
    envCache = e;
  }
  return envCache;
}

/** Postgres connection for a scope. Read scope logs in as the read-only database user. */
export function dbConfig(scope: Scope) {
  const e = env();
  const user = scope === "write" ? e.MCP_DB_USER : e.MCP_RO_DB_USER;
  const password = scope === "write" ? e.MCP_DB_PASSWORD : e.MCP_RO_DB_PASSWORD;
  if (!user || !password || !e.POSTGRES_DB) throw new Error(`database settings missing for ${scope} scope (MCP_${scope === "write" ? "" : "RO_"}DB_USER / _PASSWORD, POSTGRES_DB)`);
  return { host: e.DB_HOST || "127.0.0.1", port: Number(e.DB_PORT || e.POSTGRES_PORT || 5432), database: e.POSTGRES_DB, user, password };
}

/** KIT_SCOPE caps everything: "read" means no write tools anywhere, whatever token is used. */
export function serverScope(): Scope {
  const s = (env().KIT_SCOPE || "write").trim().toLowerCase();
  if (s === "write") return "write";
  if (s !== "read") console.error(`[client-kit] unknown KIT_SCOPE "${s}": running READ-ONLY`);
  return "read";
}

/** Optional allowlist of actor names that may write (comma separated). Empty = anyone. */
export function allowedWriters(): string[] {
  return (env().ALLOWED_WRITE_ACTORS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
}

export function approvalTtlHours(): number {
  const n = Number(env().APPROVAL_TTL_HOURS || 24);
  return Number.isFinite(n) && n > 0 ? Math.min(168, Math.round(n)) : 24;
}

export function stdioIdentity(): string {
  let user = env().MCP_USER_LABEL || "";
  if (!user) { try { user = userInfo().username; } catch { user = "unknown"; } }
  return `stdio:${user}@${env().MCP_HOST_LABEL || hostname()}`;
}
