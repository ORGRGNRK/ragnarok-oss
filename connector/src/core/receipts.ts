/**
 * Receipts for the business tools. In Ragnarok there is ONE receipt log for tool calls: the data
 * layer's hash-chained, append-only `access_log` table (see data/db/init/01_kit.sql). The old
 * ygg-mcp-business `mcp.receipts` table (not chained, could be edited) is gone on purpose.
 *
 * Who is calling (scope, actor, how they connected, session) is not part of a tool's arguments;
 * the connector puts it in `callerContext` around each call and the writer reads it from there.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import type pg from "pg";
import type { Redactor } from "./redact.js";

export interface Receipt {
  tool: string;
  args: unknown;
  ok: boolean;
  error_code?: string | null;
  duration_ms: number;
}

export interface ReceiptSink {
  write(r: Receipt): Promise<number | null>;
}

export interface CallerContext {
  scope: "read" | "write";
  /** What the caller says it is (e.g. "Claude Desktop"); falls back to the MCP client name. */
  actor: string;
  /** What the server saw: stdio:user@host or http:<token name>@<address>. */
  via: string;
  session: string;
  /** MCP client name/version from the initialize handshake. */
  client: string;
  /** The model the caller SAYS it runs on (optional `model_claimed` argument); a claim, never checked.
   *  Business tool receipts have model_reported NULL: the server makes no model call it could read a name from. */
  model_claimed?: string;
}

export const callerContext = new AsyncLocalStorage<CallerContext>();

const MAX_ARGS_CHARS = 4000;

/**
 * Writes one access_log row per tool call (the database chains it into the hash chain and makes it
 * append-only). Arguments are redacted before storage. A failed receipt write is reported to
 * `onError` (stderr) and never turns a successful tool call into a failure.
 */
export class AccessLogReceiptWriter implements ReceiptSink {
  private readonly onError: (msg: string) => void;
  private readonly fallback: CallerContext;

  constructor(
    private readonly pool: Pick<pg.Pool, "query">,
    private readonly redactor: Redactor,
    opts: { fallback?: Partial<CallerContext>; onError?: (msg: string) => void } = {},
  ) {
    this.onError = opts.onError ?? (() => {});
    this.fallback = { scope: "read", actor: "unknown", via: "unknown", session: "none", client: "unknown", ...opts.fallback };
  }

  async write(r: Receipt): Promise<number | null> {
    const c = callerContext.getStore() ?? this.fallback;
    try {
      let args: unknown = this.redactor.value(r.args ?? {});
      const s = JSON.stringify(args);
      if (s.length > MAX_ARGS_CHARS) args = { preview: s.slice(0, MAX_ARGS_CHARS) + "..." };
      const detail = { client: c.client, args, error_code: r.error_code ?? null, duration_ms: Math.round(r.duration_ms) };
      const res = await this.pool.query(
        `INSERT INTO access_log (event_uid, tool, ok, scope, actor, via, session, detail, model_reported, model_claimed) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,NULL,$9) RETURNING seq`,
        [randomUUID(), r.tool, r.ok, c.scope, c.actor, c.via, c.session, JSON.stringify(detail), c.model_claimed ?? null],
      );
      const seq = (res.rows[0] as { seq?: unknown } | undefined)?.seq;
      return seq === undefined || seq === null ? null : Number(seq);
    } catch (err) {
      this.onError(this.redactor.text(`receipt write failed for ${r.tool}: ${(err as Error).message}`));
      return null;
    }
  }
}

/** In-memory sink for unit tests. */
export class MemoryReceiptSink implements ReceiptSink {
  readonly rows: Receipt[] = [];
  async write(r: Receipt): Promise<number> {
    this.rows.push(r);
    return this.rows.length;
  }
}
