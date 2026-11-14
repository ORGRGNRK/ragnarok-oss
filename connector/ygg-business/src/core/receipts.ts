import type { Client, PoolClient } from "pg";
import type pg from "pg";
import type { Redactor } from "./redact.js";

/**
 * Hardening the MCP Tool Receipt Loop.
 * Enforces a strict transaction block, advisory lock, execution, and cryptographically
 * chained ledger insertion. Commits only if BOTH succeed.
 */
export async function executeMcpToolWithReceipt(
  dbClient: Client | PoolClient | any,
  toolName: string,
  payload: any,
  executeAction: () => Promise<any>,
): Promise<any> {
  // 1. Initialize a strict transaction block
  await dbClient.query("BEGIN");

  try {
    // 2. Take an advisory lock to prevent race condition out-of-order writes
    await dbClient.query("SELECT pg_advisory_xact_lock(hashtext($1))", [toolName]);

    // 3. Run the tool action first
    const result = await executeAction();

    // 4. Force insertion into the cryptographically chained ledger
    // This will trigger your BEFORE INSERT hashing logic automatically
    await dbClient.query(
      `INSERT INTO mcp.receipts (tool_name, payload, status) 
       VALUES ($1, $2, 'verified')`,
      [toolName, JSON.stringify(payload ?? {})],
    );

    // 5. Commit only if BOTH the action succeeded and the hash chain validated
    await dbClient.query("COMMIT");
    return result;
  } catch (error) {
    // 6. Roll back the entire execution block if the hash chain fails or the tool breaks
    try {
      await dbClient.query("ROLLBACK");
    } catch {
      // rollback error suppressed
    }
    console.error(`Ragnarok Security Exception: MCP state mutation refused.`, error);
    throw new Error("Execution aborted: Cryptographic ledger validation failure.");
  }
}

export interface Receipt {
  tool: string;
  args: unknown;
  ok: boolean;
  error_code?: string | null;
  duration_ms: number;
}

export interface ReceiptSink {
  write(r: Receipt): Promise<number | null>;
  executeWithReceipt?<T>(toolName: string, payload: unknown, action: () => Promise<T>): Promise<T>;
}

export class PgReceiptWriter implements ReceiptSink {
  private readonly table: string;
  private readonly onError: (msg: string) => void;

  constructor(
    private readonly pool: pg.Pool,
    private readonly redactor: Redactor,
    opts: { schema?: string; onError?: (msg: string) => void } = {},
  ) {
    const schema = opts.schema ?? "mcp";
    if (!/^[a-z_][a-z0-9_]*$/.test(schema)) throw new Error("invalid receipts schema name");
    this.table = `${schema}.receipts`;
    this.onError = opts.onError ?? (() => {});
  }

  async executeWithReceipt<T>(toolName: string, payload: unknown, action: () => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      return await executeMcpToolWithReceipt(
        client,
        toolName,
        this.redactor.value(payload ?? {}),
        action,
      );
    } finally {
      client.release();
    }
  }

  async write(r: Receipt): Promise<number | null> {
    try {
      const status = r.ok ? "verified" : "failed";
      const payload = {
        args: r.args ?? {},
        ok: r.ok,
        error_code: r.error_code ?? null,
        duration_ms: Math.round(r.duration_ms),
      };
      const res = await this.pool.query<{ id?: number; seq?: number }>(
        `insert into ${this.table} (tool_name, payload, status) values ($1, $2::jsonb, $3) returning seq`,
        [r.tool, JSON.stringify(this.redactor.value(payload)), status],
      );
      return res.rows[0]?.seq ?? res.rows[0]?.id ?? null;
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
  async executeWithReceipt<T>(_toolName: string, _payload: unknown, action: () => Promise<T>): Promise<T> {
    return await action();
  }
}
