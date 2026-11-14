/**
 * Error model.
 *
 * Two classes of failure, kept apart on purpose:
 *
 * 1. Protocol errors (McpError from the SDK): the request itself is malformed
 *    or names something that does not exist (unknown tool). These surface as
 *    JSON-RPC errors and the model cannot fix them by changing arguments.
 *
 * 2. Tool execution errors (ToolError): the request was well-formed but the
 *    tool could not do the work: bad argument values, not found, timeout, rate
 *    limit, upstream unavailable. These come back as a normal tool result with
 *    isError: true, so the model can read them and self-correct.
 *
 * Every ToolError says what failed, why, whether a retry is safe, and how to fix.
 */
import { ErrorCode, McpError } from "@modelcontextprotocol/sdk/types.js";

export type ToolErrorCode =
  | "invalid_argument"
  | "invalid_cursor"
  | "not_found"
  | "timeout"
  | "rate_limited"
  | "upstream_unavailable"
  | "permission_denied"
  | "not_configured"
  | "internal";

export interface ToolErrorShape {
  code: ToolErrorCode;
  what: string;
  why: string;
  retry_safe: boolean;
  fix: string;
  /** Optional hint, e.g. for rate limits. */
  retry_after_ms?: number;
}

export class ToolError extends Error {
  readonly code: ToolErrorCode;
  readonly what: string;
  readonly why: string;
  readonly retry_safe: boolean;
  readonly fix: string;
  readonly retry_after_ms?: number;

  constructor(shape: ToolErrorShape) {
    super(`${shape.what}: ${shape.why}`);
    this.name = "ToolError";
    this.code = shape.code;
    this.what = shape.what;
    this.why = shape.why;
    this.retry_safe = shape.retry_safe;
    this.fix = shape.fix;
    if (shape.retry_after_ms !== undefined) this.retry_after_ms = shape.retry_after_ms;
  }

  toJSON(): ToolErrorShape {
    const out: ToolErrorShape = {
      code: this.code,
      what: this.what,
      why: this.why,
      retry_safe: this.retry_safe,
      fix: this.fix,
    };
    if (this.retry_after_ms !== undefined) out.retry_after_ms = this.retry_after_ms;
    return out;
  }

  /** One-paragraph human-readable form used as the text content of an error result. */
  toText(): string {
    return (
      `Error [${this.code}] ${this.what}. Why: ${this.why}. ` +
      `Retry safe: ${this.retry_safe ? "yes" : "no"}` +
      (this.retry_after_ms !== undefined ? ` (retry after ~${this.retry_after_ms} ms)` : "") +
      `. Fix: ${this.fix}`
    );
  }
}

/** Protocol error for a tool name the server does not expose. */
export function unknownToolError(name: string, known: string[]): McpError {
  return new McpError(
    ErrorCode.InvalidParams,
    `Unknown tool "${name}". Call tools/list; available tools: ${known.join(", ")}`,
  );
}

export { McpError, ErrorCode };

/** Postgres SQLSTATE / node error codes mapped to ToolErrors. */
export function mapDatabaseError(err: unknown, what: string): ToolError {
  if (err instanceof ToolError) return err;
  const e = err as { code?: string; message?: string };
  const code = e?.code ?? "";
  if (code === "57014") {
    return new ToolError({
      code: "timeout",
      what,
      why: "the database cancelled the query because it exceeded the statement timeout",
      retry_safe: true,
      fix: "narrow the request (smaller limit or a filter) and retry",
    });
  }
  if (code === "42501") {
    return new ToolError({
      code: "permission_denied",
      what,
      why: "the database role used by this server lacks permission for this query",
      retry_safe: false,
      fix: "operator: check the role grants described in the operator notes",
    });
  }
  if (code === "42P01" || code === "3F000") {
    return new ToolError({
      code: "not_configured",
      what,
      why: "a table or schema this tool needs does not exist",
      retry_safe: false,
      fix: "operator: run ./kit up in ragnarok/data (it creates the tables), then retry",
    });
  }
  if (
    ["ECONNREFUSED", "ENOTFOUND", "ETIMEDOUT", "ECONNRESET", "57P01", "57P03", "08006", "08001", "28P01"].includes(code)
  ) {
    return new ToolError({
      code: "upstream_unavailable",
      what,
      why: `the database is unreachable or refused the connection (${code})`,
      retry_safe: true,
      fix: "check that the Postgres container is running and the connection URL is correct, then retry",
    });
  }
  return new ToolError({
    code: "internal",
    what,
    why: `unexpected error: ${e?.message ?? String(err)}`,
    retry_safe: false,
    fix: "report this with the access_log receipt number; do not retry blindly",
  });
}
