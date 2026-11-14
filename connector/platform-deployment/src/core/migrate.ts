import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type pg from "pg";

/**
 * Apply every *.sql file in `dir`, in name order, each inside one transaction.
 * The files themselves must be idempotent (create ... if not exists), so the
 * runner keeps no migration-history table.
 */
export async function applySqlDir(pool: pg.Pool, dir: string): Promise<string[]> {
  const files = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
  const client = await pool.connect();
  try {
    for (const f of files) {
      const sql = await readFile(join(dir, f), "utf8");
      await client.query("begin");
      try {
        await client.query(sql);
        await client.query("commit");
      } catch (err) {
        await client.query("rollback");
        throw new Error(`migration ${f} failed: ${(err as Error).message}`);
      }
    }
  } finally {
    client.release();
  }
  return files;
}
