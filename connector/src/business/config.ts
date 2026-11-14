/**
 * Business tool settings. Database logins are NOT configured here: the connector reuses the data
 * layer's logins (read-only login for business reads, read/write login only for the search cache).
 * Everything below is optional tuning from environment variables.
 */
export interface BusinessConfig {
  embedderUrl: string;
  embedderModel: string;
  statementTimeoutMs: number;
  toolTimeoutMs: number;
  searchTimeoutMs: number;
  embedderTimeoutMs: number;
  rateCapacity: number;
  rateRefillPerSecond: number;
}

function int(env: Record<string, string | undefined>, key: string, dflt: number, min: number, max: number): number {
  const raw = env[key];
  if (raw === undefined || raw === "") return dflt;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < min || n > max) throw new Error(`${key} must be a number between ${min} and ${max}`);
  return n;
}

/** Hosts that count as "this machine or the local network". Anything else is refused. */
export function isLocalHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  return (
    h === "localhost" || h === "::1" || h === "host.docker.internal" || h.endsWith(".local") || h.endsWith(".internal") ||
    /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) ||
    /^[a-z0-9-]+$/.test(h) // a bare name like "ollama" = a container on the same docker network
  );
}

export function loadConfig(env: Record<string, string | undefined> = process.env): BusinessConfig {
  // Search embeddings must come from a LOCAL Ollama, never a cloud AI service.
  const embedderUrl = env.BUSINESS_EMBEDDER_URL || "http://127.0.0.1:11434";
  let host = "";
  try { host = new URL(embedderUrl).hostname; } catch { throw new Error("BUSINESS_EMBEDDER_URL is not a valid URL"); }
  if (!isLocalHost(host)) throw new Error(`BUSINESS_EMBEDDER_URL must point at this machine or the local network (got host "${host}"): no cloud AI`);
  return {
    embedderUrl,
    embedderModel: env.BUSINESS_EMBEDDER_MODEL || "nomic-embed-text",
    statementTimeoutMs: int(env, "BUSINESS_STATEMENT_TIMEOUT_MS", 5_000, 100, 120_000),
    toolTimeoutMs: int(env, "BUSINESS_TOOL_TIMEOUT_MS", 10_000, 100, 120_000),
    searchTimeoutMs: int(env, "BUSINESS_SEARCH_TIMEOUT_MS", 120_000, 1_000, 600_000),
    embedderTimeoutMs: int(env, "BUSINESS_EMBEDDER_TIMEOUT_MS", 15_000, 100, 120_000),
    rateCapacity: int(env, "BUSINESS_RATE_CAPACITY", 30, 1, 10_000),
    rateRefillPerSecond: int(env, "BUSINESS_RATE_PER_SECOND", 5, 0.1, 10_000),
  };
}
