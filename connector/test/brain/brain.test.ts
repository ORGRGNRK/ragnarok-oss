// brain_* tools (the fix memory, moved here from brain/fix-memory's fixloop-mcp).
// Unit tests run anywhere; the MCP + database tests need ./kit test (BUSINESS_*_DATABASE_URL), use an
// offline stand-in embedder (no model) and the real hash-chained receipt logs of the throwaway database.
import { createHash } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import type { AddressInfo } from "node:net";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { errorSignature, OllamaBrainEmbedder, setBrainEmbedder, type BrainEmbedder } from "../../src/brain.js";
import { modelName } from "../../src/tools.js";
import { APP_URL, READ_URL, hasDb } from "../helpers/db.js";

class Stub768 implements BrainEmbedder {
  readonly model = "stub-768"; readonly baseUrl = "stub://"; calls: string[] = [];
  down = false;
  async embed(text: string) {
    if (this.down) throw new Error("the brain embedder could not be reached: stub is down");
    this.calls.push(text);
    const v = new Array<number>(768).fill(0);
    for (const w of text.toLowerCase().match(/[a-z0-9]+/g) ?? []) v[createHash("md5").update(w).digest().readUInt32BE(0) % 768] += 1;
    if (v.every((x) => x === 0)) v[0] = 1;
    return { vector: v, model_reported: "stub-768:reported" };
  }
}

describe("modelName (what a receipt's model column may hold)", () => {
  it("keeps a printable name up to 200 characters; anything else is null", () => {
    expect(modelName("qwen2.5-coder:7b")).toBe("qwen2.5-coder:7b");
    expect(modelName("  llama3.2:3b\n\u0000")).toBe("llama3.2:3b");
    expect(modelName("m".repeat(500))).toHaveLength(200);
    expect(modelName("")).toBeNull();
    expect(modelName(42)).toBeNull();
    expect(modelName(undefined)).toBeNull();
  });
});

describe("errorSignature (same rules as fixloop.loop.error_signature)", () => {
  it("keeps E / FAILED / ERROR / exception lines, trimmed, without repeats", () => {
    const log = ["collected 4 items", "  E   assert 1 == 2", "    def test_x():", "E   assert 1 == 2", "FAILED t.py::test_x - assert 1 == 2",
      "ERROR t.py - ImportError", "ValueError: bad", "mod.CustomException happened", "Errors are fine", "NotAnErrorline"].join("\n");
    expect(errorSignature(log)).toBe(["E   assert 1 == 2", "FAILED t.py::test_x - assert 1 == 2", "ERROR t.py - ImportError", "ValueError: bad", "mod.CustomException happened"].join("\n"));
  });
  it("caps at 2000 characters, and falls back to the log's last 1500 characters", () => {
    expect(errorSignature(Array.from({ length: 300 }, (_, i) => `E line number ${i}`).join("\n"))).toHaveLength(2000);
    const plain = "x".repeat(3000) + "END";
    expect(errorSignature(plain)).toBe(plain.slice(-1500));
  });
});

describe("OllamaBrainEmbedder", () => {
  let srv: HttpServer; let base = ""; const seen: any[] = [];
  beforeAll(async () => {
    srv = createServer((req, res) => {
      let body = ""; req.on("data", (c) => (body += c));
      req.on("end", () => { seen.push({ url: req.url, body: JSON.parse(body || "{}") }); res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ model: "nomic-embed-text:latest", embeddings: [[0.5, 0.25, 0.125]] })); });
    });
    await new Promise<void>((r) => srv.listen(0, "127.0.0.1", r));
    base = `http://127.0.0.1:${(srv.address() as AddressInfo).port}`;
  });
  afterAll(() => new Promise<void>((r) => srv.close(() => r())));

  it("calls /api/embed with the nomic task prefix, like fixloop", async () => {
    const e = new OllamaBrainEmbedder(base, "nomic-embed-text");
    const got = await e.embed("E assert 1 == 2", "query");
    expect(got.vector).toEqual([0.5, 0.25, 0.125]);
    expect(got.model_reported).toBe("nomic-embed-text:latest");   // the name in Ollama's answer, not the configured one
    await e.embed("E assert 1 == 2", "document");
    expect(seen[0]).toEqual({ url: "/api/embed", body: { model: "nomic-embed-text", input: "search_query: E assert 1 == 2" } });
    expect(seen[1].body.input).toBe("search_document: E assert 1 == 2");
  });
  it("refuses a non-local (cloud) URL", () => {
    expect(() => new OllamaBrainEmbedder("https://api.openai.com")).toThrow(/local network/);
    expect(() => new OllamaBrainEmbedder("http://192.168.1.50:11434")).not.toThrow();
  });
  it("an unreachable embedder is a clear upstream_unavailable error", async () => {
    await expect(new OllamaBrainEmbedder("http://127.0.0.1:9", "m", 2000).embed("x", "query")).rejects.toMatchObject({ code: "upstream_unavailable" });
  });
});

describe.skipIf(!hasDb)("brain_* tools through the connector's MCP server", () => {
  const stub = new Stub768();
  let admin: pg.Pool;   // the read/write login; only used to look at receipts and rows
  let W: Client; let R: Client; let closeAll: () => Promise<void>;
  const ACTOR = "vitest-brain";
  const tag = `bt${Date.now().toString(36)}`;
  const ERR = `FAILED test_${tag}.py::test_median - assert 1 == 2\nE   assert 1 == 2\n  +  where 1 = median([3, 1, 2])`;
  const call = async (c: Client, name: string, args: Record<string, unknown>) => (await c.callTool({ name, arguments: args })) as any;
  const access = async (seq: number) => (await admin.query(`SELECT tool, ok, scope, actor, via, session, detail, receipt_v, model_reported, model_claimed FROM access_log WHERE seq = $1`, [seq])).rows[0];

  beforeAll(async () => {
    const r = new URL(READ_URL as string); const w = new URL(APP_URL as string);
    Object.assign(process.env, {
      DB_HOST: w.hostname, DB_PORT: w.port || "5432", POSTGRES_DB: w.pathname.slice(1),
      MCP_DB_USER: decodeURIComponent(w.username), MCP_DB_PASSWORD: decodeURIComponent(w.password),
      MCP_RO_DB_USER: decodeURIComponent(r.username), MCP_RO_DB_PASSWORD: decodeURIComponent(r.password),
      KIT_SCOPE: "write", ALLOWED_WRITE_ACTORS: "",
    });
    setBrainEmbedder(stub);
    const { buildServer, closeBusiness } = await import("../../src/server.js");
    const { closeDb } = await import("../../src/db.js");
    admin = new pg.Pool({ connectionString: APP_URL, max: 1 });
    const connect = async (scope: "read" | "write") => {
      const [ct, st] = InMemoryTransport.createLinkedPair();
      const s = buildServer(scope, `vitest:${scope}`, "vitest-brain-session"); await s.connect(st);
      const c = new Client({ name: "vitest-brain", version: "0" }); await c.connect(ct); return { c, s };
    };
    const w1 = await connect("write"); const r1 = await connect("read");
    W = w1.c; R = r1.c;
    closeAll = async () => { await W.close(); await R.close(); await w1.s.close(); await r1.s.close(); await closeBusiness(); await closeDb(); await admin.end(); };
  });
  afterAll(async () => { setBrainEmbedder(undefined); await closeAll?.(); });

  it("lists all 4 brain tools with a write login, and hides brain_record_fix in read scope", async () => {
    const w = (await W.listTools()).tools.map((t) => t.name).filter((n) => n.startsWith("brain_")).sort();
    const r = (await R.listTools()).tools.map((t) => t.name).filter((n) => n.startsWith("brain_")).sort();
    expect(w).toEqual(["brain_list_receipts", "brain_record_fix", "brain_search_fixes", "brain_verify_receipts"]);
    expect(r).toEqual(["brain_list_receipts", "brain_search_fixes", "brain_verify_receipts"]);
    const listed = (await W.listTools()).tools.filter((t) => t.name.startsWith("brain_"));
    expect(listed.every((t) => (t.inputSchema.required as string[]).includes("actor"))).toBe(true);
  });

  it("a call without actor is refused, and receipted", async () => {
    const res = await call(W, "brain_search_fixes", { error_text: ERR });
    expect(res.isError).toBe(true);
    const row = await access(res.structuredContent.access_log_seq);
    expect(row).toMatchObject({ tool: "brain_search_fixes", ok: false });
    expect(String(row.detail.error)).toMatch(/actor/);
  });

  let fixId = 0; let receiptSeq = 0; let receiptHash = "";
  it("brain_record_fix stores the fix, the database receipts it, and it is CONFIRMED after COMMIT", async () => {
    const res = await call(W, "brain_record_fix", { actor: ACTOR, session: "s-brain", error_text: ERR, cause: "median() did not sort", fix: "--- a/stats.py\n+++ b/stats.py\n+    xs = sorted(xs)", project: tag });
    expect(res.isError, res.content?.[0]?.text).toBe(false);
    const d = res.structuredContent;
    expect(d.status).toBe("CONFIRMED");
    fixId = d.fix_id; receiptSeq = d.receipt_seq; receiptHash = d.receipt_hash;
    expect(fixId).toBeGreaterThan(0);
    const wl = (await admin.query(`SELECT action, table_name, record_id, actor, session, note, hash, new_value FROM write_log WHERE seq = $1`, [receiptSeq])).rows[0];
    expect(wl).toMatchObject({ action: "INSERT", table_name: "brain_fixes", record_id: String(fixId), actor: `${ACTOR} via vitest:write`, session: "s-brain",
      note: `fix learned (mcp) for ${tag}: median() did not sort`, hash: receiptHash });
    expect(wl.new_value).toMatchObject({ source: "mcp", project: tag, error_text: ERR, cause: "median() did not sort" });
    expect(wl.new_value.detail.embed_model).toBe("stub-768");
    const vec = (await admin.query(`SELECT embed_model FROM brain.fix_vectors WHERE fix_id = $1`, [fixId])).rows[0];
    expect(vec?.embed_model).toBe("stub-768");
    expect(stub.calls.at(-1)).toBe(errorSignature(ERR));   // embedded the signature, not the whole log
    const row = await access(d.access_log_seq);
    expect(row).toMatchObject({ tool: "brain_record_fix", ok: true, scope: "write", actor: ACTOR, via: "vitest:write", session: "s-brain" });
    expect(row.detail.args).toEqual({ project: tag, cause: "median() did not sort" });   // no error text / diff in the access log
  });

  it("brain_search_fixes finds it first, with its receipt hash; k is clamped to 1-10", async () => {
    const res = await call(R, "brain_search_fixes", { actor: ACTOR, error_text: `noise\n${ERR}\nmore noise`, k: 50 });
    expect(res.isError, res.content?.[0]?.text).toBe(false);
    const top = res.structuredContent.fixes[0];
    expect(Number(top.id)).toBe(fixId);
    expect(top.similarity).toBe(1);
    expect(top.receipt_hash).toBe(receiptHash);
    expect(res.structuredContent.fixes.length).toBeLessThanOrEqual(10);
    const row = await access(res.structuredContent.access_log_seq);
    expect(row).toMatchObject({ tool: "brain_search_fixes", ok: true, scope: "read", via: "vitest:read" });
    expect(row.detail.args).toEqual({ k: 50, error_chars: `noise\n${ERR}\nmore noise`.length });
    const one = await call(R, "brain_search_fixes", { actor: ACTOR, error_text: ERR, k: 0 });
    expect(one.structuredContent.fixes).toHaveLength(1);
  });

  it("brain_list_receipts shows the new receipt first; limit is clamped", async () => {
    const res = await call(R, "brain_list_receipts", { actor: ACTOR, limit: 0 });
    expect(res.isError).toBe(false);
    expect(res.structuredContent.receipts).toHaveLength(1);
    expect(res.structuredContent.receipts[0]).toMatchObject({ seq: receiptSeq, table_name: "brain_fixes", kind: "fix_recorded", project: tag, hash: receiptHash });
    const big = await call(R, "brain_list_receipts", { actor: ACTOR, limit: 1000 });
    expect(big.structuredContent.receipts.length).toBeLessThanOrEqual(100);
  });

  it("brain_verify_receipts reports both chains intact", async () => {
    const res = await call(R, "brain_verify_receipts", { actor: ACTOR });
    expect(res.isError).toBe(false);
    expect(res.structuredContent).toMatchObject({ ok: true });
    expect(res.structuredContent.checked).toBeGreaterThan(0);
    expect(res.structuredContent.message).toMatch(/write_log: INTACT .*access_log: INTACT|access_log: INTACT .*write_log: INTACT/);
  });

  it("brain_record_fix is not available in read scope (refused and receipted)", async () => {
    await expect(R.callTool({ name: "brain_record_fix", arguments: { actor: ACTOR, error_text: ERR, cause: "c", fix: "f" } })).rejects.toThrow(/Unknown tool/);
    const last = (await admin.query(`SELECT tool, ok, scope FROM access_log ORDER BY seq DESC LIMIT 1`)).rows[0];
    expect(last).toEqual({ tool: "brain_record_fix", ok: false, scope: "read" });
  });

  it("receipts carry the model the embedding API reported, apart from the model the client CLAIMS", async () => {
    const res = await call(W, "brain_record_fix", { actor: ACTOR, model_claimed: "claude-sonnet-claimed", error_text: `${ERR}\nE second`, cause: "model names", fix: "f", project: tag });
    expect(res.isError, res.content?.[0]?.text).toBe(false);
    const row = await access(res.structuredContent.access_log_seq);
    expect(row).toMatchObject({ tool: "brain_record_fix", ok: true, actor: ACTOR, receipt_v: 2, model_reported: "stub-768:reported", model_claimed: "claude-sonnet-claimed" });
    expect(row.detail.args).not.toHaveProperty("model_claimed");
    const wl = (await admin.query(`SELECT new_value FROM write_log WHERE seq = $1`, [res.structuredContent.receipt_seq])).rows[0];
    expect(wl.new_value.detail).toEqual({ embed_model: "stub-768", embed_model_reported: "stub-768:reported" });
    const s = await call(R, "brain_search_fixes", { actor: ACTOR, error_text: ERR });
    expect(await access(s.structuredContent.access_log_seq)).toMatchObject({ receipt_v: 2, model_reported: "stub-768:reported", model_claimed: null });
    // no model call made by the server -> model_reported stays NULL, whatever the client claims
    const l = await call(R, "brain_list_receipts", { actor: ACTOR, model_claimed: "gpt-claimed" });
    expect(await access(l.structuredContent.access_log_seq)).toMatchObject({ receipt_v: 2, model_reported: null, model_claimed: "gpt-claimed" });
    const v = (await admin.query(`SELECT bool_and(intact) AS ok FROM kit_verify()`)).rows[0];
    expect(v.ok).toBe(true);
  });

  it("a model_claimed over 200 characters is refused (and receipted without it)", async () => {
    const res = await call(R, "brain_list_receipts", { actor: ACTOR, model_claimed: "x".repeat(201) });
    expect(res.isError).toBe(true);
    expect(await access(res.structuredContent.access_log_seq)).toMatchObject({ tool: "brain_list_receipts", ok: false, model_claimed: "x".repeat(200) });
  });

  it("if the embedder is down, nothing is stored and the failure is receipted", async () => {
    const before = Number((await admin.query(`SELECT count(*) AS n FROM brain.brain_fixes`)).rows[0].n);
    stub.down = true;
    try {
      const res = await call(W, "brain_record_fix", { actor: ACTOR, error_text: ERR, cause: "c", fix: "f", project: tag });
      expect(res.isError).toBe(true);
      expect(res.content[0].text).toMatch(/nothing was changed/);
      expect(await access(res.structuredContent.access_log_seq)).toMatchObject({ tool: "brain_record_fix", ok: false });
    } finally { stub.down = false; }
    expect(Number((await admin.query(`SELECT count(*) AS n FROM brain.brain_fixes`)).rows[0].n)).toBe(before);
  });
});
