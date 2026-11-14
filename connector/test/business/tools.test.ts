import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { OllamaEmbedder } from "../../src/core/search/embedder.js";
import { McpError } from "../../src/core/errors.js";
import { call, hasDb, startHarness, type Harness } from "../helpers/db.js";
import { StubEmbedder } from "../helpers/stub-embedder.js";

const TOOLS = [
  "business_get_item",
  "business_list_exit_profiles",
  "business_list_items",
  "business_list_leads",
  "business_search_items",
  "business_summarize_items",
];

describe.skipIf(!hasDb)("Business tools against the throwaway test database (fake rows)", () => {
  let h: Harness;
  let total = 0;
  beforeAll(async () => {
    h = await startHarness(new StubEmbedder("stub-business-tests"));
    total = Number((await h.readPool.query('select count(*) as n from public."Business"')).rows[0].n);
  });
  afterAll(async () => h?.close());

  const receiptCount = async (tool: string) =>
    Number((await h.appPool.query("select count(*) as n from access_log where tool = $1", [tool])).rows[0].n);

  it("exposes the six business_ tools with object input schemas and descriptions", async () => {
    const { tools } = await h.client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual(TOOLS);
    for (const t of tools) {
      expect(t.inputSchema.type).toBe("object");
      expect(t.description!.length).toBeGreaterThan(20);
      expect(t.annotations?.readOnlyHint).toBe(true);
    }
  });

  it("business_list_items pages through every item once via next_cursor", async () => {
    const seen: number[] = [];
    let cursor: string | undefined;
    let pages = 0;
    do {
      const r = await call(h, "business_list_items", { limit: 25, ...(cursor ? { cursor } : {}) });
      expect(r.isError).toBeFalsy();
      expect(r.content[0]!.type).toBe("text");
      expect(r.structuredContent).toHaveProperty("next_cursor");
      seen.push(...r.structuredContent!.items.map((i: any) => i.id));
      cursor = r.structuredContent!.next_cursor ?? undefined;
      pages++;
    } while (cursor && pages < 20);
    expect(seen.length).toBe(total);
    expect(new Set(seen).size).toBe(total);
    expect([...seen]).toEqual([...seen].sort((a, b) => a - b));
  });

  it("business_list_items filters by status case-insensitively", async () => {
    const r = await call(h, "business_list_items", { status: "sold", limit: 100 });
    const n = Number((await h.readPool.query(`select count(*) as n from public."Business" where "Status" = 'Sold'`)).rows[0].n);
    expect(r.structuredContent!.items).toHaveLength(n);
    expect(r.structuredContent!.items.every((i: any) => i.status === "Sold")).toBe(true);
    expect(r.structuredContent!.next_cursor).toBeNull();
  });

  it("business_get_item finds by id and by uid, masking IMEIs", async () => {
    const byId = await call(h, "business_get_item", { id: 13 });
    expect(byId.isError).toBeFalsy();
    const uid = byId.structuredContent!.item.uid;
    const byUid = await call(h, "business_get_item", { uid });
    expect(byUid.structuredContent!.item.id).toBe(13);
    expect(byUid.content[0]!.text).toContain(uid);
    expect(byId.structuredContent!.item).not.toHaveProperty("imei");
    const last4 = byId.structuredContent!.item.imei_last4;
    if (last4 !== null) expect(String(last4).length).toBeLessThanOrEqual(4);
  });

  it("business_summarize_items totals match SQL", async () => {
    const r = await call(h, "business_summarize_items", { group_by: "category" });
    const sql = (await h.readPool.query(
      `select count(*) as n, count(distinct nullif("Category", '')) as g,
              sum("Net_Profit") filter (where "Sold_Price" is not null) as np from public.business_with_totals`,
    )).rows[0];
    expect(r.structuredContent!.totals.count).toBe(Number(sql.n));
    expect(r.structuredContent!.groups.filter((g: any) => g.key !== null)).toHaveLength(Number(sql.g));
    expect(r.structuredContent!.totals.realized_net_profit).toBeCloseTo(Number(sql.np), 2);
    expect(r.content[0]!.text).toMatch(/item\(s\) in \d+ category group/);
  });

  it("business_list_leads and business_list_exit_profiles return pages (empty tables are fine)", async () => {
    for (const [tool, table] of [["business_list_leads", '"Leads"'], ["business_list_exit_profiles", '"Exit Profiles"']] as const) {
      const r = await call(h, tool, { limit: 100 });
      const n = Number((await h.readPool.query(`select count(*) as n from public.${table}`)).rows[0].n);
      expect(r.isError).toBeFalsy();
      expect(r.structuredContent!.items).toHaveLength(Math.min(n, 100));
      expect(r.structuredContent).toHaveProperty("next_cursor");
      expect(r.content[0]!.text).toMatch(/\d+ (lead|exit profile)/);
    }
    const active = await call(h, "business_list_exit_profiles", { active_only: true });
    expect(active.structuredContent!.items.every((i: any) => i.active === true)).toBe(true);
  });

  it("every tool call writes a receipt with redacted args", async () => {
    const calls: Array<[string, Record<string, unknown>]> = [
      ["business_list_items", { limit: 1 }],
      ["business_get_item", { id: 1 }],
      ["business_summarize_items", { group_by: "status" }],
      ["business_list_leads", {}],
      ["business_list_exit_profiles", {}],
      ["business_search_items", { query: "iphone", limit: 1 }],
    ];
    for (const [tool, args] of calls) {
      const before = await receiptCount(tool);
      await call(h, tool, args);
      expect(await receiptCount(tool), tool).toBe(before + 1);
    }
    const last = await h.appPool.query(`select detail->'args' as args_redacted, ok from access_log where tool = 'business_get_item' order by seq desc limit 1`);
    expect(last.rows[0]).toEqual({ args_redacted: { id: 1 }, ok: true });
  });

  it("fails: unknown tool name is a protocol error", async () => {
    await expect(h.client.callTool({ name: "business_delete_items", arguments: {} })).rejects.toBeInstanceOf(McpError);
  });

  it("fails: missing required argument (group_by) is an invalid_argument tool error", async () => {
    const r = await call(h, "business_summarize_items", {});
    expect(r.isError).toBe(true);
    expect(r.structuredContent!.error).toMatchObject({ code: "invalid_argument", retry_safe: true });
    expect(r.structuredContent!.error.why).toMatch(/group_by/);
  });

  it("fails: wrong argument type (limit as string) is rejected", async () => {
    const r = await call(h, "business_list_items", { limit: "ten" });
    expect(r.isError).toBe(true);
    expect(r.structuredContent!.error.why).toMatch(/limit/);
  });

  it("fails: out-of-range limit is rejected with the allowed range", async () => {
    const r = await call(h, "business_list_items", { limit: 1000 });
    expect(r.isError).toBe(true);
    expect(r.content[0]!.text).toMatch(/limit: .*100/);
  });

  it("fails: malformed cursor and a cursor reused with other filters are invalid_cursor", async () => {
    const bad = await call(h, "business_list_items", { cursor: "not-a-real-cursor" });
    expect(bad.structuredContent!.error).toMatchObject({ code: "invalid_cursor", retry_safe: false });
    expect(bad.structuredContent!.error.fix).toMatch(/omit `cursor`/);
    const first = await call(h, "business_list_items", { limit: 2 });
    const reused = await call(h, "business_list_items", { limit: 2, status: "Sold", cursor: first.structuredContent!.next_cursor });
    expect(reused.structuredContent!.error.code).toBe("invalid_cursor");
  });

  it("fails: nonexistent item id is not_found with a way forward", async () => {
    const r = await call(h, "business_get_item", { id: 999999 });
    expect(r.isError).toBe(true);
    expect(r.structuredContent!.error).toMatchObject({ code: "not_found", retry_safe: false });
    expect(r.structuredContent!.error.fix).toMatch(/business_list_items/);
    const both = await call(h, "business_get_item", { id: 1, uid: "INV-2026-001" });
    expect(both.structuredContent!.error.why).toMatch(/exactly one of id or uid/);
  });

  it("fails: embedder unreachable makes search return a retry-safe tool error", async () => {
    const down = await startHarness(new OllamaEmbedder({ baseUrl: "http://127.0.0.1:9", model: "nomic-embed-text", timeoutMs: 2000 }));
    try {
      const r = await call(down, "business_search_items", { query: "iphone" });
      expect(r.isError).toBe(true);
      expect(r.structuredContent!.error).toMatchObject({ code: "upstream_unavailable", retry_safe: true });
      expect(r.content[0]!.text).toMatch(/retry/i);
    } finally {
      await down.close();
    }
  });

  it("fails: query timeout from the database maps to a retry-safe timeout error", async () => {
    // Prove the statement_timeout path end-to-end with the read role.
    const err = await h.readPool.query("set local statement_timeout = 50; select pg_sleep(1)").catch((e) => e);
    const { mapDatabaseError } = await import("../../src/core/errors.js");
    expect(mapDatabaseError(err, "q")).toMatchObject({ code: "timeout", retry_safe: true });
  });

  it("fails: rate limit exceeded on a tight per-server limiter (isolated from other tests)", async () => {
    const tight = await startHarness(new StubEmbedder("stub-business-tests"), { capacity: 1, refillPerSecond: 0.01 });
    try {
      await call(tight, "business_list_leads", {});
      const r = await call(tight, "business_list_leads", {});
      expect(r.structuredContent!.error).toMatchObject({ code: "rate_limited", retry_safe: true });
    } finally {
      await tight.close();
    }
  });

  it("fails: database password is redacted from receipts and errors", async () => {
    const pw = new URL(process.env.BUSINESS_READ_DATABASE_URL!).password;
    await call(h, "business_list_items", { status: decodeURIComponent(pw) });
    const r = await h.appPool.query(`select (detail->'args')::text as a from access_log where tool = 'business_list_items' order by seq desc limit 1`);
    expect(r.rows[0].a).not.toContain(decodeURIComponent(pw));
    expect(r.rows[0].a).toContain("***");
  });
});
