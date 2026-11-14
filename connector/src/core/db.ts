import pg from "pg";

/**
 * Create a connection pool with boring, explicit defaults:
 * - statement_timeout so no query runs unbounded,
 * - dates/timestamps returned as strings (no local-timezone shifting,
 *   no loss of microseconds when they are fed back as keyset positions),
 * - numeric returned as JS numbers (values here are money/counts, well within range).
 */
export function createPool(opts: {
  connectionString: string;
  applicationName: string;
  statementTimeoutMs: number;
  max?: number;
  readOnly?: boolean;
}): pg.Pool {
  const pool = new pg.Pool({
    connectionString: opts.connectionString,
    application_name: opts.applicationName,
    statement_timeout: opts.statementTimeoutMs,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 10_000,
    max: opts.max ?? 4,
    // Read pools refuse writes at the session level as a second fence behind role grants.
    ...(opts.readOnly ? { options: "-c default_transaction_read_only=on" } : {}),
    types: {
      getTypeParser: ((oid: number, format?: string) => {
        if (oid === 1082 || oid === 1114 || oid === 1184) return (v: string) => v; // date, timestamp, timestamptz
        if (oid === 1700) return (v: string) => (v === null ? null : Number(v)); // numeric
        if (oid === 20) return (v: string) => Number(v); // int8 (counts)
        return pg.types.getTypeParser(oid, format as "text");
      }) as typeof pg.types.getTypeParser,
    },
  });
  // An idle-client error must not crash a stdio server; the next query reports it.
  pool.on("error", () => {});
  return pool;
}

export type Pool = pg.Pool;
