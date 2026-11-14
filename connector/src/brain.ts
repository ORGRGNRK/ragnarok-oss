// brain_* tools: the fix memory (brain/fix-memory) served by the connector. Moved here on 2026-10-30
// from the separate Python stdio server `fixloop-mcp` (brain/fix-memory/fixloop/mcp_server.py), so
// Ragnarok has ONE MCP server. Same 4 tools, same SQL, same search vectors (nomic-embed-text through
// Ollama's /api/embed, "search_query: " / "search_document: " prefixes, the same error signature),
// so fixes stored by `fixloop` and fixes stored here are found by each other.
// Receipts follow the connector's rules like every other tool: actor required, one access_log row
// per call (refusals too), and brain_record_fix is a write: hidden in read scope, ALLOWED_WRITE_ACTORS
// applies, the database's write_log trigger receipts the new fix, and it is read back after COMMIT.
// No cloud AI: the embedder URL must be this machine or the local network.
import type pg from "pg";
import { isLocalHost } from "./business/config.js";
import { env } from "./config.js";
import { ToolError } from "./core/errors.js";
import { pool } from "./db.js";
import { Refusal } from "./schema.js";
import * as T from "./tools.js";

export type BrainEmbedKind = "document" | "query";
/** model_reported: the model name in the embedding API's own response (not the configured name). */
export interface BrainEmbedding { vector: number[]; model_reported?: string | null }
export interface BrainEmbedder { readonly model: string; readonly baseUrl: string; embed(text: string, kind: BrainEmbedKind): Promise<BrainEmbedding> }

const BRAIN_TABLES = ["brain_fixes", "brain_fix_events"];

/** The lines that say what broke (pytest "E" lines, FAILED/ERROR summary lines, exception lines);
 *  the whole log's last 1500 characters if there are none. Same as fixloop.loop.error_signature. */
export function errorSignature(error: string): string {
  const keep: string[] = [];
  for (const line of error.split(/\r\n|\r|\n/)) {
    const st = line.trim();
    if (st.startsWith("E ") || st.startsWith("FAILED ") || st.startsWith("ERROR ") || /^[A-Za-z_.]*(Error|Exception)\b/.test(st)) {
      if (!keep.includes(st)) keep.push(st);
    }
  }
  return keep.length ? keep.join("\n").slice(0, 2000) : error.slice(-1500);
}

/** Ollama POST /api/embed {model, input}: the call fixloop makes, so the vectors are the same. */
export class OllamaBrainEmbedder implements BrainEmbedder {
  readonly baseUrl: string;
  constructor(baseUrl: string, readonly model = "nomic-embed-text", private readonly timeoutMs = 120_000) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    let host = "";
    try { host = new URL(this.baseUrl).hostname; } catch { throw new Error(`brain embedder URL is not a valid URL: ${baseUrl}`); }
    if (!isLocalHost(host)) throw new Error(`BRAIN_OLLAMA_URL must point at this machine or the local network (got host "${host}"): no cloud AI`);
  }
  async embed(text: string, kind: BrainEmbedKind): Promise<BrainEmbedding> {
    const prefix = kind === "query" ? "search_query: " : "search_document: ";
    const url = `${this.baseUrl}/api/embed`;
    let res: Response;
    try {
      res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: this.model, input: prefix + text }), signal: AbortSignal.timeout(this.timeoutMs) });
    } catch (err) {
      const c = (err as { cause?: { code?: string } })?.cause;
      throw new ToolError({ code: "upstream_unavailable", what: "the brain embedder could not be reached",
        why: `no answer from ${this.baseUrl} for model ${this.model} (${c?.code ?? (err as Error)?.name ?? "fetch failed"})`,
        retry_safe: true, fix: `start Ollama at ${this.baseUrl} with ${this.model} pulled (or set BRAIN_OLLAMA_URL), then retry` });
    }
    if (!res.ok) {
      const body = (await res.text().catch(() => "")).slice(0, 200);
      throw new ToolError({ code: "upstream_unavailable", what: "the brain embedder returned an error", why: `HTTP ${res.status} from ${url}${body ? `: ${body}` : ""}`,
        retry_safe: true, fix: res.status === 404 ? `pull the model first (ollama pull ${this.model}), then retry` : "check the Ollama logs, then retry" });
    }
    const json = (await res.json().catch(() => null)) as { embeddings?: unknown[]; model?: unknown } | null;
    const v = json?.embeddings?.[0];
    if (!Array.isArray(v) || v.length === 0 || !v.every((x) => typeof x === "number"))
      throw new ToolError({ code: "upstream_unavailable", what: "the brain embedder returned no usable vector", why: `response from ${url} had no numeric "embeddings[0]"`,
        retry_safe: true, fix: `confirm ${this.model} is an embedding model and the URL points at the Ollama API, then retry` });
    return { vector: v as number[], model_reported: T.modelName(json?.model) };
  }
}

let embedder: BrainEmbedder | undefined;
/** BRAIN_OLLAMA_URL, else BUSINESS_EMBEDDER_URL, else this machine. BRAIN_EMBED_MODEL (default nomic-embed-text). */
export function brainEmbedder(): BrainEmbedder {
  if (!embedder) {
    const e = env();
    embedder = new OllamaBrainEmbedder(e.BRAIN_OLLAMA_URL || e.BUSINESS_EMBEDDER_URL || "http://127.0.0.1:11434", e.BRAIN_EMBED_MODEL || "nomic-embed-text");
  }
  return embedder;
}
/** Tests swap in an offline embedder. */
export function setBrainEmbedder(e: BrainEmbedder | undefined) { embedder = e; }

const vec = (v: number[]) => `[${v.map((x) => x.toFixed(7)).join(",")}]`;
const clamp = (n: number | undefined, dflt: number, lo: number, hi: number) => Math.max(lo, Math.min(n ?? dflt, hi));

// ------------------------------------------------------------------ the 4 tools

export function searchFixes(ctx: T.Ctx, who: T.Who, a: { error_text: string; k?: number }): Promise<T.Result> {
  const k = a.k ?? 3;
  return T.runRead(ctx, who, "brain_search_fixes", { k, error_chars: a.error_text.length }, async (q) => {
    const e = await brainEmbedder().embed(errorSignature(a.error_text), "query");
    const v = vec(e.vector);
    const rows = (await q.query(
      `SELECT f.id, f.source, f.project, f.error_text, f.cause, f.fix,
              (SELECT w.hash FROM write_log w WHERE w.table_name = 'brain_fixes'
                 AND w.record_id = f.id::text AND w.action = 'INSERT' ORDER BY w.seq DESC LIMIT 1) AS receipt_hash,
              1 - (v.embedding <=> $1::vector) AS similarity
       FROM brain.fix_vectors v JOIN brain.brain_fixes f ON f.id = v.fix_id
       ORDER BY v.embedding <=> $1::vector LIMIT $2`, [v, clamp(k, 3, 1, 10)])).rows;
    const fixes = rows.map((r) => ({ ...r, similarity: Math.round(Number(r.similarity) * 10_000) / 10_000 }));
    const text = fixes.length
      ? `${fixes.length} stored fix(es), most similar first:\n` + fixes.map((f) =>
        `- fix #${f.id} similarity ${f.similarity} (${f.source}${f.project ? `, ${f.project}` : ""}) cause: ${String(f.cause ?? "").slice(0, 200)}\n  receipt hash ${f.receipt_hash ?? "(none)"}`).join("\n")
      : "No stored fixes yet.";
    return { ok: true, text, data: { fixes }, model_reported: e.model_reported ?? null };
  });
}

export async function recordFix(ctx: T.Ctx, who: T.Who, a: { error_text: string; cause: string; fix: string; project?: string | null }): Promise<T.Result> {
  const project = a.project ?? null;
  const note = `fix learned (mcp) for ${project || "unknown project"}: ${a.cause.slice(0, 200)}`;
  let saved: { fix_id: number; receipt_seq: number; receipt_hash: string } | undefined;
  const r = await T.runWrite(ctx, who, "brain_record_fix", { project, cause: a.cause.slice(0, 200) }, note, async (q) => {
    const em = brainEmbedder();
    const e = await em.embed(errorSignature(a.error_text), "document");
    const detail = { embed_model: em.model, embed_model_reported: e.model_reported ?? null };
    const id = Number((await q.query(
      `INSERT INTO brain.brain_fixes (source, project, error_text, cause, fix, detail) VALUES ('mcp',$1,$2,$3,$4,$5::jsonb) RETURNING id`,
      [project, a.error_text, a.cause, a.fix, JSON.stringify(detail)])).rows[0].id);
    await q.query(`INSERT INTO brain.fix_vectors (fix_id, embedding, embed_model) VALUES ($1, $2::vector, $3)`, [id, vec(e.vector), em.model]);
    const row = (await q.query(`SELECT project, error_text, cause, fix FROM brain.brain_fixes WHERE id = $1`, [id])).rows[0];
    if (!row || row.project !== project || row.error_text !== a.error_text || row.cause !== a.cause || row.fix !== a.fix)
      throw new Refusal("read-back of the new fix did not match, so nothing was saved");
    const rc = (await q.query(`SELECT seq, hash FROM write_log WHERE table_name = 'brain_fixes' AND record_id = $1 AND action = 'INSERT' ORDER BY seq DESC LIMIT 1`, [String(id)])).rows[0];
    if (!rc) throw new Error(`no write_log receipt for brain_fixes #${id}: is data/db/brain.sql applied (./kit up)? -- rolled back`);
    saved = { fix_id: id, receipt_seq: Number(rc.seq), receipt_hash: rc.hash as string };
    return { touched: [], data: { ...saved }, model_reported: e.model_reported ?? null };
  });
  if (!r.ok || !saved) return r;
  // After COMMIT, from a fresh connection: is the fix really there, with its receipt and vector?
  const p = pool(ctx.scope);
  const there = (await p.query(`SELECT (SELECT count(*) FROM brain.brain_fixes WHERE id = $1) AS f, (SELECT count(*) FROM brain.fix_vectors WHERE fix_id = $1) AS v,
      (SELECT hash FROM write_log WHERE seq = $2) AS h`, [saved.fix_id, saved.receipt_seq])).rows[0];
  const ok = Number(there.f) === 1 && Number(there.v) === 1 && there.h === saved.receipt_hash;
  const head = `${ok ? "CONFIRMED" : "UNCONFIRMED"}  fix #${saved.fix_id} stored and read back` + (ok ? "" : " -- PROBLEM: not found after COMMIT") +
    `\n  RECEIPT write_log #${saved.receipt_seq} (hash ${saved.receipt_hash.slice(0, 16)}...)`;
  return { ok, text: `${head}\n${r.text.replace(/^\n+/, "")}`, data: { ...(r.data ?? {}), status: ok ? "CONFIRMED" : "UNCONFIRMED" } };
}

export function listReceipts(ctx: T.Ctx, who: T.Who, a: { limit?: number }): Promise<T.Result> {
  const limit = a.limit ?? 10;
  return T.runRead(ctx, who, "brain_list_receipts", { limit }, async (q: pg.PoolClient) => {
    const rows = (await q.query(
      `SELECT seq, created_at, table_name, record_id, actor, session, note, prev_hash, hash,
              new_value->>'kind' AS kind, new_value->>'source' AS source, new_value->>'project' AS project,
              new_value->>'fix_id' AS fix_id, left(new_value->>'cause', 120) AS cause
       FROM write_log WHERE table_name = ANY($1) ORDER BY seq DESC LIMIT $2`, [BRAIN_TABLES, clamp(limit, 10, 1, 100)])).rows;
    const receipts = rows.map((r) => ({ ...r, created_at: new Date(r.created_at).toISOString(), kind: r.kind ?? (r.table_name === "brain_fixes" ? "fix_recorded" : "event") }));
    const text = receipts.length
      ? `${receipts.length} brain receipt(s), newest first:\n` + receipts.map((r) => `- write_log #${r.seq} ${r.kind} ${r.table_name} #${r.record_id} by ${r.actor} at ${r.created_at}${r.note ? ` -- ${r.note}` : ""}\n  hash ${r.hash}`).join("\n")
      : "No brain receipts yet.";
    return { ok: true, text, data: { receipts } };
  });
}

export function verifyBrainReceipts(ctx: T.Ctx, who: T.Who): Promise<T.Result> {
  return T.runRead(ctx, who, "brain_verify_receipts", {}, async (q) => {
    const rows = (await q.query(`SELECT chain, rows_checked, intact, first_bad_seq, problem FROM kit_verify()`)).rows;
    const ok = rows.length > 0 && rows.every((r) => r.intact);
    const checked = rows.reduce((n, r) => n + Number(r.rows_checked), 0);
    const message = rows.map((r) => `${r.chain}: ${r.intact ? "INTACT" : `BROKEN at #${r.first_bad_seq}`} (${r.rows_checked} rows)${r.problem && !r.intact ? ` ${r.problem}` : ""}`).join("; ");
    return { ok: true, text: `${ok ? "INTACT" : "BROKEN"} -- ${message}`, data: { ok, checked, message } };
  });
}
