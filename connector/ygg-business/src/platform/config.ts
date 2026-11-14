/**
 * Configuration for the Docker MCP platform.
 * Reads environment variables with secure defaults and no personal credentials stored in code.
 */

export interface PlatformConfig {
  readUrl: string;
  ownerUrl: string;
  requireAuth: boolean;
  sessionTtlMinutes: number;
  unlockSecret?: string;
  embedderUrl: string;
  embedderModel: string;
  statementTimeoutMs: number;
  toolTimeoutMs: number;
  searchTimeoutMs: number;
  embedderTimeoutMs: number;
  rateCapacity: number;
  rateRefillPerSecond: number;
}

const num = (v: string | undefined, dflt: number): number => {
  if (v === undefined) return dflt;
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`invalid positive number: "${v}"`);
  return n;
};

export function loadPlatformConfig(env: NodeJS.ProcessEnv = process.env): PlatformConfig {
  const readUrl = env.APP_READ_DATABASE_URL || env.BUSINESS_READ_DATABASE_URL;
  if (!readUrl) throw new Error("fatal: missing configuration APP_READ_DATABASE_URL");

  const ownerUrl = env.APP_OWNER_DATABASE_URL || env.BUSINESS_APP_DATABASE_URL;
  if (!ownerUrl) throw new Error("fatal: missing configuration APP_OWNER_DATABASE_URL");

  const requireAuth = env.PLATFORM_REQUIRE_AUTH !== "false";
  const sessionTtlMinutes = num(env.PLATFORM_SESSION_TTL_MINUTES, 60);

  return {
    readUrl,
    ownerUrl,
    requireAuth,
    sessionTtlMinutes,
    unlockSecret: env.PLATFORM_UNLOCK_SECRET || undefined,
    embedderUrl: env.PLATFORM_EMBEDDER_URL || env.BUSINESS_EMBEDDER_URL || "http://127.0.0.1:11434",
    embedderModel: env.PLATFORM_EMBEDDER_MODEL || env.BUSINESS_EMBEDDER_MODEL || "nomic-embed-text",
    statementTimeoutMs: num(env.PLATFORM_STATEMENT_TIMEOUT_MS || env.BUSINESS_STATEMENT_TIMEOUT_MS, 5_000),
    toolTimeoutMs: num(env.PLATFORM_TOOL_TIMEOUT_MS || env.BUSINESS_TOOL_TIMEOUT_MS, 10_000),
    searchTimeoutMs: num(env.PLATFORM_SEARCH_TIMEOUT_MS || env.BUSINESS_SEARCH_TIMEOUT_MS, 120_000),
    embedderTimeoutMs: num(env.PLATFORM_EMBEDDER_TIMEOUT_MS || env.BUSINESS_EMBEDDER_TIMEOUT_MS, 15_000),
    rateCapacity: num(env.PLATFORM_RATE_CAPACITY || env.BUSINESS_RATE_CAPACITY, 30),
    rateRefillPerSecond: num(env.PLATFORM_RATE_PER_SECOND || env.BUSINESS_RATE_PER_SECOND, 5),
  };
}
