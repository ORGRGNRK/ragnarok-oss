/**
 * Lazy, incremental vector index stored in plain Postgres.
 *
 * Storage fallback: pgvector is not installed on the target server, so vectors
 * are stored as real[] in <schema>.search_vectors and ranked by cosine
 * similarity in TypeScript. This is fine for hundreds-to-low-thousands of rows;
 * see the risk register for the limit and the migration path to pgvector.
 *
 * Incremental rule: <schema>.index_state holds, per model, the (updated_at, id)
 * of the last row indexed. sync() asks the source only for rows strictly after
 * that position, embeds the ones whose content hash changed, upserts them and
 * advances the position batch by batch (so an interrupted sync keeps its progress).
 */
import { createHash } from "node:crypto";
import type pg from "pg";
import { ToolError } from "../errors.js";
import type { Embedder } from "./embedder.js";

export interface SourceRow {
  id: number;
  /** Timestamp as text exactly as Postgres prints it (keeps microseconds). */
  updated_at: string;
  /** Text to embed. */
  text: string;
}

export interface IndexSource {
  /** Rows with (updated_at, id) > after, ordered by (updated_at, id), at most `limit`. */
  rowsAfter(after: { updated_at: string; id: number } | null, limit: number): Promise<SourceRow[]>;
}

export interface SyncStats {
  embedded: number;
  unchanged: number;
  scanned: number;
}

export function cosine(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    const x = a[i] as number;
    const y = b[i] as number;
    dot += x * y;
    na += x * x;
    nb += y * y;
  }
  return na === 0 || nb === 0 ? 0 : dot / (Math.sqrt(na) * Math.sqrt(nb));
}

export class VectorIndex {
  private readonly s: string;

  constructor(
    private readonly pool: pg.Pool,
    private readonly embedder: Embedder,
    private readonly source: IndexSource,
    opts: { schema?: string; batchSize?: number } = {},
  ) {
    const schema = opts.schema ?? "mcp";
    if (!/^[a-z_][a-z0-9_]*$/.test(schema)) throw new Error("invalid index schema name");
    this.s = schema;
    this.batchSize = opts.batchSize ?? 32;
  }

  private readonly batchSize: number;

  async state(): Promise<{ updated_at: string; id: number } | null> {
    const r = await this.pool.query<{ last_updated_at: string; last_id: number }>(
      `select last_updated_at::text as last_updated_at, last_id from ${this.s}.index_state where model = $1`,
      [this.embedder.model],
    );
    const row = r.rows[0];
    return row ? { updated_at: row.last_updated_at, id: Number(row.last_id) } : null;
  }

  /** Embed only what changed since the last sync for this model. */
  async sync(signal?: AbortSignal): Promise<SyncStats> {
    const stats: SyncStats = { embedded: 0, unchanged: 0, scanned: 0 };
    let pos = await this.state();
    for (;;) {
      if (signal?.aborted) break;
      const rows = await this.source.rowsAfter(pos, this.batchSize);
      if (rows.length === 0) break;
      stats.scanned += rows.length;

      const hashes = rows.map((r) => createHash("sha256").update(r.text).digest("hex"));
      const existing = await this.pool.query<{ item_id: number; content_hash: string }>(
        `select item_id, content_hash from ${this.s}.search_vectors where model = $1 and item_id = any($2::bigint[])`,
        [this.embedder.model, rows.map((r) => r.id)],
      );
      const known = new Map(existing.rows.map((r) => [Number(r.item_id), r.content_hash]));
      const todo = rows.map((r, i) => ({ r, h: hashes[i] as string })).filter(({ r, h }) => known.get(r.id) !== h);
      stats.unchanged += rows.length - todo.length;

      const vectors = todo.length ? await this.embedder.embed(todo.map((t) => t.r.text), "document", signal) : [];
      stats.embedded += todo.length;
      const last = rows[rows.length - 1] as SourceRow;

      const client = await this.pool.connect();
      try {
        await client.query("begin");
        for (let i = 0; i < todo.length; i++) {
          const { r, h } = todo[i] as { r: SourceRow; h: string };
          await client.query(
            `insert into ${this.s}.search_vectors (item_id, model, embedding, content_hash, updated_at)
             values ($1, $2, $3::real[], $4, $5::timestamp)
             on conflict (item_id, model) do update
               set embedding = excluded.embedding, content_hash = excluded.content_hash,
                   updated_at = excluded.updated_at, indexed_at = now()`,
            [r.id, this.embedder.model, vectors[i], h, r.updated_at],
          );
        }
        // Advance only forward, so concurrent syncs cannot move the position back.
        await client.query(
          `insert into ${this.s}.index_state (model, last_updated_at, last_id) values ($1, $2::timestamp, $3)
           on conflict (model) do update set last_updated_at = excluded.last_updated_at, last_id = excluded.last_id, synced_at = now()
           where (${this.s}.index_state.last_updated_at, ${this.s}.index_state.last_id) < (excluded.last_updated_at, excluded.last_id)`,
          [this.embedder.model, last.updated_at, last.id],
        );
        await client.query("commit");
      } catch (err) {
        await client.query("rollback").catch(() => {});
        throw err;
      } finally {
        client.release();
      }
      pos = { updated_at: last.updated_at, id: last.id };
      if (rows.length < this.batchSize) break;
    }
    return stats;
  }

  /** Rank all stored vectors for this model against a query vector. */
  async rank(query: number[], k: number): Promise<Array<{ item_id: number; score: number }>> {
    const r = await this.pool.query<{ item_id: number; embedding: number[] }>(
      `select item_id, embedding from ${this.s}.search_vectors where model = $1`,
      [this.embedder.model],
    );
    const scored: Array<{ item_id: number; score: number }> = [];
    for (const row of r.rows) {
      const v = row.embedding.map(Number);
      if (v.length !== query.length) {
        throw new ToolError({
          code: "internal",
          what: "search index is inconsistent",
          why: `stored vectors have ${v.length} dimensions but the query has ${query.length} (model changed under the same name?)`,
          retry_safe: false,
          fix: `operator: delete rows for model '${this.embedder.model}' from ${this.s}.search_vectors and ${this.s}.index_state so the next search re-indexes`,
        });
      }
      scored.push({ item_id: Number(row.item_id), score: cosine(query, v) });
    }
    scored.sort((a, b) => b.score - a.score || a.item_id - b.item_id);
    return scored.slice(0, k);
  }
}
