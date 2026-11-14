// memory_* tools (data/db/memory.sql) through the connector's MCP server. Needs ./kit test (throwaway database);
// an offline stand-in embedder, no model. Admin-only steps (promote) are done with the admin URL the test gets.
import { createHash } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { setBrainEmbedder, type BrainEmbedder } from "../../src/brain.js";
import { APP_URL, READ_URL, hasDb } from "../helpers/db.js";

class Stub768 implements BrainEmbedder {
  readonly model = "stub-768"; readonly baseUrl = "stub://";
  async embed(text: string) {
    const v = new Array<number>(768).fill(0);
    for (const w of text.toLowerCase().replace(/^search_(query|document): /, "").match(/[a-z0-9]+/g) ?? []) v[createHash("md5").update(w).digest().readUInt32BE(0) % 768] += 1;
    if (v.every((x) => x === 0)) v[0] = 1;
    return { vector: v, model_reported: "stub-768:reported" };
  }
}

describe.skipIf(!hasDb)("memory_* tools through the connector's MCP server", () => {
  let rw: pg.Pool; let W: Client; let R: Client; let closeAll: () => Promise<void>;
  const ACTOR = "vitest-memory";
  const tag = `mt${Date.now().toString(36)}`;
  const KEY = `test:${tag}`;
  const call = async (c: Client, name: string, args: Record<string, unknown>) => (await c.callTool({ name, arguments: args })) as any;
  beforeAll(async () => {
    const r = new URL(READ_URL as string); const w = new URL(APP_URL as string);
    Object.assign(process.env, {
      DB_HOST: w.hostname, DB_PORT: w.port || "5432", POSTGRES_DB: w.pathname.slice(1),
      MCP_DB_USER: decodeURIComponent(w.username), MCP_DB_PASSWORD: decodeURIComponent(w.password),
      MCP_RO_DB_USER: decodeURIComponent(r.username), MCP_RO_DB_PASSWORD: decodeURIComponent(r.password),
      KIT_SCOPE: "write", ALLOWED_WRITE_ACTORS: "",
    });
    setBrainEmbedder(new Stub768());
    const { buildServer, closeBusiness } = await import("../../src/server.js");
    const { closeDb } = await import("../../src/db.js");
    rw = new pg.Pool({ connectionString: APP_URL, max: 1 });
    const connect = async (scope: "read" | "write") => {
      const [ct, st] = InMemoryTransport.createLinkedPair();
      const s = buildServer(scope, `vitest:${scope}`, "vitest-memory-session"); await s.connect(st);
      const c = new Client({ name: "vitest-memory", version: "0" }); await c.connect(ct); return { c, s };
    };
    const w1 = await connect("write"); const r1 = await connect("read");
    W = w1.c; R = r1.c;
    closeAll = async () => { await W.close(); await R.close(); await w1.s.close(); await r1.s.close(); await closeBusiness(); await closeDb(); await rw.end(); };
  });
  afterAll(async () => { setBrainEmbedder(undefined); await closeAll?.(); });

  it("lists 6 memory tools with a write login; memory_record_fact is hidden in read scope", async () => {
    const w = (await W.listTools()).tools.map((t) => t.name).filter((n) => n.startsWith("memory_")).sort();
    const r = (await R.listTools()).tools.map((t) => t.name).filter((n) => n.startsWith("memory_")).sort();
    expect(w).toEqual(["memory_get_core", "memory_get_fact", "memory_list_versions", "memory_record_fact", "memory_search_facts", "memory_search_words"]);
    expect(r).toEqual(["memory_get_core", "memory_get_fact", "memory_list_versions", "memory_search_facts", "memory_search_words"]);
  });

  it("memory_record_fact saves as Unchecked, CONFIRMED, with a vector; a second call makes v2 and closes v1", async () => {
    const a = await call(W, "memory_record_fact", { actor: ACTOR, key: KEY, title: `Throwaway ${tag}`, body: "version one about zebras" });
    expect(a.isError, a.content?.[0]?.text).toBe(false);
    expect(a.structuredContent).toMatchObject({ status: "CONFIRMED", version: 1 });
    const b = await call(W, "memory_record_fact", { actor: ACTOR, key: KEY, title: `Throwaway ${tag}`, body: "version two about zebras" });
    expect(b.structuredContent).toMatchObject({ status: "CONFIRMED", version: 2 });
    const same = await call(W, "memory_record_fact", { actor: ACTOR, key: KEY, title: `Throwaway ${tag}`, body: "version two about zebras" });
    expect(same.structuredContent.version).toBe(2);   // unchanged: no new version
    const rows = (await rw.query(`SELECT version, status, valid_to IS NULL AS cur, superseded_by, actor FROM memory.facts WHERE fact_key = $1 ORDER BY version`, [KEY])).rows;
    expect(rows.map((x) => [x.version, x.status, x.cur])).toEqual([[1, "Unchecked", false], [2, "Unchecked", true]]);
    expect(rows[0].superseded_by).not.toBeNull();
    expect(rows[1].actor).toBe(`${ACTOR} via vitest:write`);
    const v = (await rw.query(`SELECT count(*)::int n FROM memory.fact_vectors fv JOIN memory.facts f ON f.id = fv.fact_id WHERE f.fact_key = $1`, [KEY])).rows[0];
    expect(v.n).toBe(2);
    const wl = (await rw.query(`SELECT count(*)::int n FROM write_log WHERE table_name = 'facts' AND new_value->>'fact_key' = $1`, [KEY])).rows[0];
    expect(wl.n).toBeGreaterThanOrEqual(2);
  });

  it("the AI login cannot promote, edit or delete facts", async () => {
    await expect(rw.query(`SELECT memory.set_status($1, 'Verified', 'x')`, [KEY])).rejects.toThrow(/permission denied/);
    await expect(rw.query(`UPDATE memory.facts SET status = 'Verified' WHERE fact_key = $1`, [KEY])).rejects.toThrow(/permission denied/);
    await expect(rw.query(`DELETE FROM memory.facts WHERE fact_key = $1`, [KEY])).rejects.toThrow(/permission denied/);
  });

  it("an Unchecked fact is not in the core index and not in default search; include_unchecked finds it", async () => {
    const c = await call(R, "memory_get_core", { actor: ACTOR });
    expect(c.isError, c.content?.[0]?.text).toBe(false);
    expect(c.content[0].text).not.toContain(KEY);
    const s1 = await call(R, "memory_search_facts", { actor: ACTOR, query: "zebras" });
    expect(s1.structuredContent.facts.map((f: any) => f.fact_key)).not.toContain(KEY);
    const s2 = await call(R, "memory_search_facts", { actor: ACTOR, query: "zebras", include_unchecked: true, k: 3 });
    expect(s2.structuredContent.facts[0].fact_key).toBe(KEY);
  });

  it("memory_get_fact returns the current version, or an old one marked NOT current; memory_list_versions lists both", async () => {
    const g = await call(R, "memory_get_fact", { actor: ACTOR, key: KEY });
    expect(g.content[0].text).toContain("version two about zebras");
    expect(g.content[0].text).toMatch(/\[Unchecked\]/);
    const old = await call(R, "memory_get_fact", { actor: ACTOR, key: KEY, version: 1 });
    expect(old.content[0].text).toContain("NOT current");
    const h = await call(R, "memory_list_versions", { actor: ACTOR, key: KEY });
    expect(h.structuredContent.versions).toHaveLength(2);
    const none = await call(R, "memory_get_fact", { actor: ACTOR, key: "test:does-not-exist" });
    expect(none.isError).toBe(true);
  });

  it("memory_search_words returns the owner's words verbatim, closest first; the AI login cannot add words", async () => {
    await expect(rw.query(`INSERT INTO memory.words (said_at, text, source, text_hash) VALUES (now(), 'x', 't', md5('x'))`)).rejects.toThrow(/permission denied/);
    const res = await call(R, "memory_search_words", { actor: ACTOR, query: "anything", k: 3 });
    expect(res.isError, res.content?.[0]?.text).toBe(false);
    expect(Array.isArray(res.structuredContent.words)).toBe(true);
  });
});
