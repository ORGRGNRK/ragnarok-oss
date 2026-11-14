import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { afterEach, describe, expect, it } from "vitest";
import { McpError } from "../../src/core/errors.js";
import { TokenBucket } from "../../src/core/rate-limit.js";
import { AccessLogReceiptWriter, callerContext, MemoryReceiptSink } from "../../src/core/receipts.js";
import { createRedactor } from "../../src/core/redact.js";
import { defineTool, ToolHost, type ToolDef } from "../../src/core/server.js";
import { z } from "../../src/core/validate.js";

const SECRET = "Sup3rS3cretValue";

function makeHost(opts: { capacity?: number; timeoutMs?: number } = {}) {
  const receipts = new MemoryReceiptSink();
  const tools = [
    defineTool({
      name: "demo_get_echo",
      description: "Echo a word.",
      input: z.object({ word: z.string().min(1), times: z.number().int().min(1).max(3).default(1) }).strict(),
      handler: async (a) => ({ summary: `echo ${a.word}`, data: { echoed: Array(a.times).fill(a.word) } }),
    }),
    defineTool({
      name: "demo_get_slow",
      description: "Sleeps longer than the timeout.",
      input: z.object({}).strict(),
      handler: () => new Promise((res) => setTimeout(() => res({ summary: "late", data: {} }), 1000)),
    }),
    defineTool({
      name: "demo_get_leaky",
      description: "Fails with a message containing a connection string.",
      input: z.object({}).strict(),
      handler: async () => {
        throw new Error(`could not connect to postgresql://ygg_app:${SECRET}@127.0.0.1:5547/x`);
      },
    }),
  ] as unknown as ToolDef[];
  const host = new ToolHost({
    name: "demo",
    version: "0",
    tools,
    limiter: new TokenBucket({ capacity: opts.capacity ?? 100, refillPerSecond: 0.001 }),
    receipts,
    redactor: createRedactor([SECRET]),
    defaultTimeoutMs: opts.timeoutMs ?? 50,
    log: () => {},
  });
  return { host, receipts };
}

let closers: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const c of closers) await c();
  closers = [];
});

async function connect(host: ToolHost) {
  const [ct, st] = InMemoryTransport.createLinkedPair();
  const server = host.createServer();
  await server.connect(st);
  const client = new Client({ name: "t", version: "0" });
  await client.connect(ct);
  closers.push(async () => { await client.close(); await server.close(); });
  return client;
}

describe("ToolHost", () => {
  it("lists tools with object JSON Schemas", async () => {
    const client = await connect(makeHost().host);
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name)).toEqual(["demo_get_echo", "demo_get_slow", "demo_get_leaky"]);
    for (const t of tools) expect(t.inputSchema.type).toBe("object");
  });

  it("returns a text summary plus structuredContent and writes a receipt", async () => {
    const { host, receipts } = makeHost();
    const client = await connect(host);
    const r = (await client.callTool({ name: "demo_get_echo", arguments: { word: "hi", times: 2 } })) as any;
    expect(r.isError).toBeFalsy();
    expect(r.content[0]).toEqual({ type: "text", text: "echo hi" });
    expect(r.structuredContent).toEqual({ echoed: ["hi", "hi"] });
    expect(receipts.rows).toHaveLength(1);
    expect(receipts.rows[0]).toMatchObject({ tool: "demo_get_echo", ok: true });
  });

  it("rejects badly named tools at construction", () => {
    expect(() => new ToolHost({
      name: "x", version: "0", limiter: new TokenBucket({ capacity: 1, refillPerSecond: 1 }),
      receipts: new MemoryReceiptSink(), redactor: createRedactor(), defaultTimeoutMs: 10,
      tools: [{ name: "GetThing", description: "", input: z.object({}), handler: async () => ({ summary: "", data: {} }) }] as any,
    })).toThrow(/prefix_verb_noun/);
  });

  it("fails: unknown tool is a protocol error, not a tool result", async () => {
    const client = await connect(makeHost().host);
    await expect(client.callTool({ name: "demo_get_nothing", arguments: {} })).rejects.toBeInstanceOf(McpError);
    await expect(client.callTool({ name: "demo_get_nothing", arguments: {} })).rejects.toThrow(/Unknown tool.*demo_get_echo/);
  });

  it("fails: missing required argument returns an invalid_argument tool error", async () => {
    const { host, receipts } = makeHost();
    const client = await connect(host);
    const r = (await client.callTool({ name: "demo_get_echo", arguments: {} })) as any;
    expect(r.isError).toBe(true);
    expect(r.structuredContent.error).toMatchObject({ code: "invalid_argument", retry_safe: true });
    expect(r.structuredContent.error.why).toMatch(/word/);
    expect(receipts.rows[0]).toMatchObject({ ok: false, error_code: "invalid_argument" });
  });

  it("fails: wrong argument type names the field and expected type", async () => {
    const client = await connect(makeHost().host);
    const r = (await client.callTool({ name: "demo_get_echo", arguments: { word: 5 } })) as any;
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toMatch(/word: .*expected string/i);
  });

  it("fails: query timeout returns a retry-safe timeout error", async () => {
    const client = await connect(makeHost({ timeoutMs: 30 }).host);
    const r = (await client.callTool({ name: "demo_get_slow", arguments: {} })) as any;
    expect(r.isError).toBe(true);
    expect(r.structuredContent.error).toMatchObject({ code: "timeout", retry_safe: true });
  });

  it("fails: rate limit exceeded returns rate_limited with retry guidance", async () => {
    const client = await connect(makeHost({ capacity: 2 }).host);
    await client.callTool({ name: "demo_get_echo", arguments: { word: "a" } });
    await client.callTool({ name: "demo_get_echo", arguments: { word: "a" } });
    const r = (await client.callTool({ name: "demo_get_echo", arguments: { word: "a" } })) as any;
    expect(r.isError).toBe(true);
    expect(r.structuredContent.error.code).toBe("rate_limited");
    expect(r.content[0].text).toMatch(/Retry safe: yes/);
  });

  it("fails: password redacted from an error message", async () => {
    const { host, receipts } = makeHost();
    const client = await connect(host);
    const r = (await client.callTool({ name: "demo_get_leaky", arguments: {} })) as any;
    expect(r.isError).toBe(true);
    const all = JSON.stringify(r);
    expect(all).not.toContain(SECRET);
    expect(all).toContain("ygg_app:***@");
    // The secret also never reaches a successful result's text or structured output.
    const ok = (await client.callTool({ name: "demo_get_echo", arguments: { word: SECRET } })) as any;
    expect(JSON.stringify(ok)).not.toContain(SECRET);
    expect(receipts.rows).toHaveLength(2);
  });
});

// Ragnarok: receipts go to the data layer's hash-chained access_log (was: ygg's mcp.receipts).
describe("AccessLogReceiptWriter", () => {
  it("stores redacted args and never throws when the insert fails", async () => {
    const calls: unknown[][] = [];
    const okPool = { query: async (_sql: string, params: unknown[]) => { calls.push(params); return { rows: [{ seq: 7 }] }; } };
    const w = new AccessLogReceiptWriter(okPool as any, createRedactor(["hunter2x"]));
    expect(await w.write({ tool: "t_get_x", args: { token: "abc", q: "hunter2x" }, ok: true, duration_ms: 3.4 })).toBe(7);
    // event_uid, tool, ok, scope, actor, via, session, detail
    expect(calls[0]!.slice(1, 7)).toEqual(["t_get_x", true, "read", "unknown", "unknown", "none"]);
    expect(JSON.parse(calls[0]![7] as string)).toEqual({ client: "unknown", args: { token: "***", q: "***" }, error_code: null, duration_ms: 3 });
    expect(calls[0]![8]).toBeNull();   // model_claimed: none given (model_reported is always NULL for business tools)

    const errs: string[] = [];
    const badPool = { query: async () => { throw new Error("relation access_log does not exist"); } };
    const w2 = new AccessLogReceiptWriter(badPool as any, createRedactor(), { onError: (m) => errs.push(m) });
    expect(await w2.write({ tool: "t", args: {}, ok: true, duration_ms: 1 })).toBeNull();
    expect(errs[0]).toMatch(/receipt write failed/);
  });

  it("records who called (scope, actor, via, session) from the caller context", async () => {
    const calls: unknown[][] = [];
    const pool = { query: async (_sql: string, params: unknown[]) => { calls.push(params); return { rows: [{ seq: 1 }] }; } };
    const w = new AccessLogReceiptWriter(pool as any, createRedactor());
    await callerContext.run({ scope: "write", actor: "Claude", via: "http:write-token@1.2.3.4", session: "s1", client: "c/1", model_claimed: "claude-sonnet-x" }, () =>
      w.write({ tool: "t_get_x", args: {}, ok: false, error_code: "not_found", duration_ms: 1 }),
    );
    expect(calls[0]!.slice(1, 7)).toEqual(["t_get_x", false, "write", "Claude", "http:write-token@1.2.3.4", "s1"]);
    expect(JSON.parse(calls[0]![7] as string)).toMatchObject({ client: "c/1", error_code: "not_found" });
    expect(calls[0]![8]).toBe("claude-sonnet-x");   // the caller's CLAIMED model, its own column
  });
});
