import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { call, hasDb, startHarness, type Harness } from "../helpers/db.js";
import { StubEmbedder } from "../helpers/stub-embedder.js";

const MODEL = "stub-embedder";

describe.skipIf(!hasDb)("business_search_items lazy incremental index", () => {
  let h: Harness;
  let stub: StubEmbedder;
  let total = 0;

  beforeAll(async () => {
    stub = new StubEmbedder(MODEL, 1024);
    h = await startHarness(stub);
    total = Number((await h.readPool.query('select count(*) as n from public."Business"')).rows[0].n);
    // Start from an empty index for this model only (mcp schema; never public).
    await h.appPool.query("delete from mcp.search_vectors where model = $1", [MODEL]);
    await h.appPool.query("delete from mcp.index_state where model = $1", [MODEL]);
  });
  afterAll(async () => h?.close());

  it("first search embeds every item, second search embeds 0", async () => {
    const first = await call(h, "business_search_items", { query: "iphone pro", limit: 5 });
    expect(first.isError).toBeFalsy();
    expect(first.structuredContent!.index.embedded_now).toBe(total);
    expect(stub.documentsEmbedded).toBe(total);

    const second = await call(h, "business_search_items", { query: "iphone pro", limit: 5 });
    const secondEmbed = second.structuredContent!.index.embedded_now;
    console.log(`first_embed=${first.structuredContent!.index.embedded_now} second_embed=${secondEmbed}`);
    expect(secondEmbed).toBe(0);
    expect(stub.documentsEmbedded).toBe(total);

    const stored = await h.appPool.query("select count(distinct item_id) as n from mcp.search_vectors where model = $1", [MODEL]);
    expect(Number(stored.rows[0].n)).toBe(total);
  });

  it("ranks relevant items first and returns structured matches with a summary", async () => {
    const r = await call(h, "business_search_items", { query: "iphone", limit: 3 });
    expect(r.structuredContent!.items).toHaveLength(3);
    for (const i of r.structuredContent!.items) expect(String(i.item).toLowerCase()).toContain("iphone");
    expect(r.content[0]!.text).toMatch(/3 match\(es\) for "iphone"; best: /);
    const scores = r.structuredContent!.items.map((i: any) => i.score);
    expect(scores).toEqual([...scores].sort((a: number, b: number) => b - a));
  });

  it("only rows past index_state are re-examined; only changed/missing vectors are re-embedded", async () => {
    // Rewind the position by one row and drop that row's vector: exactly one row must be embedded.
    const rows = (await h.readPool.query(
      `select id, coalesce(updated_at, created_at, 'epoch'::timestamp)::text as ts from public."Business"
        order by coalesce(updated_at, created_at, 'epoch'::timestamp) desc, id desc limit 3`,
    )).rows;
    const [last, prev, prev2] = rows;
    await h.appPool.query("update mcp.index_state set last_updated_at = $2::timestamp, last_id = $3 where model = $1", [MODEL, prev2.ts, prev2.id]);
    await h.appPool.query("delete from mcp.search_vectors where model = $1 and item_id = $2", [MODEL, last.id]);
    const before = stub.documentsEmbedded;
    const r = await call(h, "business_search_items", { query: "gaming console" });
    expect(r.structuredContent!.index.embedded_now).toBe(1); // last: missing vector
    expect(r.structuredContent!.index.unchanged).toBe(1); // prev: same content hash
    expect(stub.documentsEmbedded - before).toBe(1);
    const st = (await h.appPool.query("select last_id from mcp.index_state where model = $1", [MODEL])).rows[0];
    expect(Number(st.last_id)).toBe(last.id);
    expect(prev.id).toBeDefined();
  });

  it("fails: empty query is rejected before any embedding happens", async () => {
    const before = stub.queriesEmbedded;
    const r = await call(h, "business_search_items", { query: "   " });
    expect(r.isError).toBe(true);
    expect(r.structuredContent!.error.code).toBe("invalid_argument");
    expect(stub.queriesEmbedded).toBe(before);
  });
});
