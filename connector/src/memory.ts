// memory_* tools: the memory layer (data/db/memory.sql), the same facts data/scripts/memory.py serves on the Mac.
//   memory_get_core      the index: current Verified + Timeless facts, titles only (read a fact before relying on it)
//   memory_get_fact       one fact in full (current version, or a given version), with its dates and status
//   memory_list_versions   every version of a fact: when each was true and who wrote it
//   memory_search_facts    facts by meaning (nomic-embed-text, same vectors and prefixes as memory.py)
//   memory_record_fact  write scope: add or change a fact; ALWAYS lands Unchecked (memory.remember in the database).
//                    The AI login cannot promote, retire, edit history or delete: the database refuses it.
// Recall (past chats and files, the Heimdall corpus) is NOT here: it lives on the Mac, and this server runs in Docker.
import { brainEmbedder } from "./brain.js";
import { pool } from "./db.js";
import { Refusal } from "./schema.js";
import * as T from "./tools.js";

const vec = (v: number[]) => `[${v.map((x) => x.toFixed(7)).join(",")}]`;
const clamp = (n: number | undefined, dflt: number, lo: number, hi: number) => Math.max(lo, Math.min(n ?? dflt, hi));
const day = (d: unknown) => (d ? new Date(d as string).toISOString().slice(0, 10) : null);
export const CORE_LIMIT = 9500;

export function core(ctx: T.Ctx, who: T.Who): Promise<T.Result> {
  return T.runRead(ctx, who, "memory_get_core", {}, async (q) => {
    const rows = (await q.query(`SELECT fact_key, title, kind, status, valid_from FROM memory.core ORDER BY kind NULLS LAST, id`)).rows;
    const head = { what: "RAGNAROK memory core index: the facts that are Verified or Timeless right now",
      how: "titles only; read a fact in full before relying on it (memory_get_fact)", row: ["key", "title", "status V=Verified T=Timeless", "recorded"],
      kind: "a {kind} line applies to the rows under it", count: rows.length };
    const lines = [JSON.stringify(head)]; let kind: unknown = Symbol();
    for (const r of rows) {
      if (r.kind !== kind) { kind = r.kind; lines.push(JSON.stringify({ kind })); }
      lines.push(JSON.stringify([r.fact_key, r.title, String(r.status)[0], day(r.valid_from)]));
    }
    const text = lines.join("\n");
    if (text.length > CORE_LIMIT) throw new Refusal(`core index is ${text.length} characters, over the ${CORE_LIMIT} limit: a person should retire facts or shorten titles`);
    return { ok: true, text, data: { count: rows.length, chars: text.length } };
  });
}

export function get(ctx: T.Ctx, who: T.Who, a: { key: string; version?: number }): Promise<T.Result> {
  return T.runRead(ctx, who, "memory_get_fact", { key: a.key, version: a.version ?? null }, async (q) => {
    const r = (await q.query(
      `SELECT * FROM memory.facts WHERE fact_key = $1 AND ($2::int IS NULL OR version = $2)
        ORDER BY (valid_to IS NULL) DESC, version DESC LIMIT 1`, [a.key, a.version ?? null])).rows[0];
    if (!r) throw new Refusal(`no fact ${a.key}${a.version ? ` version ${a.version}` : ""}`);
    const when = `true from ${day(r.valid_from)}` + (r.valid_to ? ` to ${day(r.valid_to)} (NOT current)` : ", current");
    const text = [`${r.fact_key} v${r.version} [${r.status}] ${r.title}`,
      `${when}; source: ${r.source}; written by: ${r.actor}${r.last_verified ? `; last verified ${day(r.last_verified)}` : ""}`,
      ...(r.description ? [r.description] : []), "", r.body, ...(r.checks ? ["", `Checks: ${r.checks}`] : [])].join("\n");
    return { ok: true, text, data: { fact: { ...r, current: !r.valid_to } } };
  });
}

export function history(ctx: T.Ctx, who: T.Who, a: { key: string }): Promise<T.Result> {
  return T.runRead(ctx, who, "memory_list_versions", { key: a.key }, async (q) => {
    const rows = (await q.query(`SELECT id, version, status, title, valid_from, valid_to, actor, source FROM memory.facts WHERE fact_key = $1 ORDER BY version`, [a.key])).rows;
    if (!rows.length) throw new Refusal(`no fact ${a.key}`);
    const text = rows.map((r) => `v${r.version} [${r.status}] ${new Date(r.valid_from).toISOString().slice(0, 16)} -> ${r.valid_to ? new Date(r.valid_to).toISOString().slice(0, 16) : "now"}  ${r.title}  (${r.actor})`).join("\n");
    return { ok: true, text, data: { versions: rows } };
  });
}

export function search(ctx: T.Ctx, who: T.Who, a: { query: string; k?: number; include_unchecked?: boolean }): Promise<T.Result> {
  const k = clamp(a.k, 6, 1, 20);
  return T.runRead(ctx, who, "memory_search_facts", { k, include_unchecked: !!a.include_unchecked, query_chars: a.query.length }, async (q) => {
    const e = await brainEmbedder().embed(a.query, "query");
    const rows = (await q.query(
      `SELECT f.fact_key, f.title, f.status, left(coalesce(f.description, f.body), 300) AS gist, 1 - (v.embedding <=> $1::vector) AS similarity
         FROM memory.fact_vectors v JOIN memory.facts f ON f.id = v.fact_id
        WHERE f.valid_to IS NULL AND ($3 OR f.status IN ('Verified', 'Timeless'))
        ORDER BY v.embedding <=> $1::vector LIMIT $2`, [vec(e.vector), k, !!a.include_unchecked])).rows
      .map((r) => ({ ...r, similarity: Math.round(Number(r.similarity) * 1000) / 1000 }));
    const text = rows.length
      ? `${rows.length} fact(s), most similar first (open one with memory_get_fact before relying on it):\n` +
        rows.map((r) => `- ${r.similarity} ${r.fact_key} [${r.status}] ${r.title}\n  ${String(r.gist).replace(/\s+/g, " ")}`).join("\n")
      : "No facts with vectors yet.";
    return { ok: true, text, data: { facts: rows }, model_reported: e.model_reported ?? null };
  });
}

export async function remember(ctx: T.Ctx, who: T.Who, a: { key: string; title: string; body: string; kind?: string; description?: string }): Promise<T.Result> {
  let saved: { fact_id: number; version: number } | undefined;
  const r = await T.runWrite(ctx, who, "memory_record_fact", { key: a.key, title: a.title.slice(0, 200) }, `remember ${a.key}`, async (q) => {
    const actor = `${who.actor} via ${ctx.via}`;
    const id = Number((await q.query(`SELECT memory.remember($1, $2, $3, $4, $5, 'mcp', $6) AS id`,
      [a.key, a.title, a.body, a.kind ?? null, a.description ?? null, actor])).rows[0].id);
    const row = (await q.query(`SELECT version, status, title, body FROM memory.facts WHERE id = $1`, [id])).rows[0];
    if (!row || row.title !== a.title || row.body !== a.body) throw new Refusal("read-back of the fact did not match, so nothing was saved");
    let model_reported: string | null = null;
    const have = (await q.query(`SELECT 1 FROM memory.fact_vectors WHERE fact_id = $1`, [id])).rowCount;
    if (!have) {
      try {
        const em = brainEmbedder();
        const e = await em.embed(`${a.title}\n${a.description ?? ""}\n${a.body}`.slice(0, 6000), "document");
        await q.query(`INSERT INTO memory.fact_vectors (fact_id, embedding, embed_model) VALUES ($1, $2::vector, $3)`, [id, vec(e.vector), em.model]);
        model_reported = e.model_reported ?? null;
      } catch { /* the fact still saves; memory.py embed fills the vector later */ }
    }
    saved = { fact_id: id, version: Number(row.version) };
    return { touched: [], text: `fact ${a.key} v${row.version} [${row.status}]`, data: { ...saved, status: row.status }, model_reported };
  });
  if (!r.ok || !saved) return r;
  const there = (await pool(ctx.scope).query(`SELECT status, (valid_to IS NULL) AS current FROM memory.facts WHERE id = $1`, [saved.fact_id])).rows[0];
  const ok = !!there && there.current && there.status === "Unchecked";
  return { ok, text: `${ok ? "CONFIRMED" : "UNCONFIRMED"}  ${a.key} v${saved.version} saved as Unchecked (a person or the checker promotes it)\n${r.text.replace(/^\n+/, "")}`,
    data: { ...(r.data ?? {}), status: ok ? "CONFIRMED" : "UNCONFIRMED" } };
}

/** The owner's own words (memory.words): their typed messages closest in meaning to query, verbatim, oldest phrasing kept.
 *  For matching how he talks. Read-only: only the importer (memory.py import-words) adds rows. */
export function searchWords(ctx: T.Ctx, who: T.Who, a: { query: string; k?: number }): Promise<T.Result> {
  const k = clamp(a.k, 8, 1, 30);
  return T.runRead(ctx, who, "memory_search_words", { k, query_chars: a.query.length }, async (q) => {
    const e = await brainEmbedder().embed(a.query, "query");
    const rows = (await q.query(
      `SELECT w.said_at, w.text, 1 - (v.embedding <=> $1::vector) AS similarity
         FROM memory.word_vectors v JOIN memory.words w ON w.id = v.word_id
        ORDER BY v.embedding <=> $1::vector LIMIT $2`, [vec(e.vector), k])).rows
      .map((r) => ({ said_on: day(r.said_at), text: r.text as string, similarity: Math.round(Number(r.similarity) * 1000) / 1000 }));
    const text = rows.length
      ? `${rows.length} of the owner's own messages, closest in meaning first (verbatim, typos kept):\n` + rows.map((r) => `- ${r.said_on}: ${r.text.replace(/\s+/g, " ").slice(0, 600)}`).join("\n")
      : "No words imported yet (memory.py import-words).";
    return { ok: true, text, data: { words: rows }, model_reported: e.model_reported ?? null };
  });
}
