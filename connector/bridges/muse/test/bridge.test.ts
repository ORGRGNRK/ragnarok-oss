// Offline: a fake Yggdrasil MCP server in memory, Muse's HTTP replies mocked. No key, no paid call.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { z } from "zod";
import { chat, newState, pickTools, runTurn, settingsFrom, type McpTool, type Settings } from "../lib.ts";

const KEY = "muse_fake_key_0123456789";
const who = { actor: z.string(), session: z.string() };

async function fakeYgg() {
  const calls: { name: string; args: any }[] = [];
  const s = new McpServer({ name: "fake-ygg", version: "0" });
  s.registerTool("list_tables", { description: "List tables", inputSchema: { ...who }, annotations: { readOnlyHint: true } }, async (a: any) => { calls.push({ name: "list_tables", args: a }); return { content: [{ type: "text", text: "Reminders -- 3 record(s)" }] }; });
  s.registerTool("get_record", { description: "Get one", inputSchema: { table: z.string(), id: z.number().int().optional(), ...who }, annotations: { readOnlyHint: true } }, async (a: any) => { calls.push({ name: "get_record", args: a }); return { content: [{ type: "text", text: `row ${a.id}` }] }; });
  s.registerTool("create_records", { description: "Create", inputSchema: { table: z.string(), records: z.array(z.record(z.string(), z.any())), ...who }, annotations: { readOnlyHint: false } }, async (a: any) => { calls.push({ name: "create_records", args: a }); return { content: [{ type: "text", text: "WRITE OK" }] }; });
  s.registerTool("ask_muse", { description: "Ask Muse", inputSchema: { question: z.string(), ...who }, annotations: { readOnlyHint: true, openWorldHint: true } }, async () => ({ content: [{ type: "text", text: "no" }] }));
  const [a, b] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "t", version: "0" });
  await Promise.all([s.connect(a), client.connect(b)]);
  const callTool = async (name: string, args: Record<string, unknown>) => {
    const r: any = await client.callTool({ name, arguments: args });
    return { text: r.content.map((c: any) => c.text).join("\n"), isError: !!r.isError };
  };
  return { client, calls, callTool, tools: (await client.listTools()).tools as McpTool[] };
}

function replies(...msgs: any[]) {
  const seen: any[] = [];
  let i = 0;
  const f = (async (url: string, init: RequestInit) => {
    seen.push({ url, body: JSON.parse(String(init.body)), auth: (init.headers as any).Authorization });
    const m = msgs[i++];
    return new Response(JSON.stringify({ choices: [{ message: m }], usage: { prompt_tokens: 100, completion_tokens: 50 } }), { status: 200 });
  }) as unknown as typeof fetch;
  return { f, seen };
}
const settings = (extra: Record<string, string> = {}) => ({ ...settingsFrom({ MODEL_API_KEY: KEY, YGG_SESSION: "s-test", ...extra }) }) as Settings;
const toolCall = (id: string, name: string, args: unknown) => ({ id, type: "function", function: { name, arguments: JSON.stringify(args) } });

describe("bridge", () => {
  it("offers only read tools by default, never Muse's own tools, and hides actor/session", async () => {
    const y = await fakeYgg();
    const { picked, skipped } = pickTools(y.tools, false);
    assert.deepEqual([...picked.keys()].sort(), ["get_record", "list_tables"]);
    assert.deepEqual(skipped.map((s) => s.name).sort(), ["ask_muse", "create_records"]);
    const st = newState(settings(), picked);
    const gr = st.tools.find((t) => t.function.name === "get_record");
    assert.deepEqual(Object.keys(gr.function.parameters.properties).sort(), ["id", "table"]);
    assert.deepEqual(gr.function.parameters.required, ["table"]);
    assert.equal("$schema" in gr.function.parameters, false);
    await y.client.close();
  });

  it("runs a tool call through MCP, injects actor/session, then returns Muse's answer", async () => {
    const y = await fakeYgg();
    const { picked } = pickTools(y.tools, false);
    const st = newState(settings(), picked);
    const { f, seen } = replies(
      { role: "assistant", content: null, tool_calls: [toolCall("c1", "list_tables", {}), toolCall("c2", "get_record", { table: "Reminders", id: 2, actor: "Spoofed" })] },
      { role: "assistant", content: "You have 3 reminders." },
    );
    const answer = await runTurn(st, "How many reminders?", { fetch: f, callTool: y.callTool, confirm: async () => { throw new Error("no writes here"); } });
    assert.equal(answer, "You have 3 reminders.");
    assert.equal(seen[0].url, "https://api.meta.ai/v1/chat/completions");
    assert.equal(seen[0].auth, `Bearer ${KEY}`);
    assert.equal(seen[0].body.model, "muse-spark-1.3");
    assert.equal(seen[0].body.reasoning_effort, "low");
    assert.equal(seen[0].body.max_completion_tokens, 4096);
    for (const k of ["stop", "logit_bias", "max_output_tokens"]) assert.equal(k in seen[0].body, false);
    assert.deepEqual(y.calls.map((c) => c.name), ["list_tables", "get_record"]);
    assert.equal(y.calls[1].args.actor, "Muse", "the bridge's actor wins over a spoofed one");
    assert.equal(y.calls[1].args.session, "s-test");
    const toolMsgs = seen[1].body.messages.filter((m: any) => m.role === "tool");
    assert.deepEqual(toolMsgs.map((m: any) => [m.tool_call_id, m.content]), [["c1", "Reminders -- 3 record(s)"], ["c2", "row 2"]]);
    assert.ok(st.spent.usd > 0);
    await y.client.close();
  });

  it("with --allow-writes every write asks first; a 'no' never reaches the server", async () => {
    const y = await fakeYgg();
    const { picked } = pickTools(y.tools, true);
    assert.equal(picked.get("create_records")?.write, true);
    const st = newState(settings(), picked);
    assert.match(st.tools.find((t) => t.function.name === "create_records").function.description, /^\[WRITES - asks the owner first\]/);
    const asked: string[] = [];
    const { f, seen } = replies(
      { role: "assistant", content: null, tool_calls: [toolCall("w1", "create_records", { table: "Reminders", records: [{ Task: "x" }] })] },
      { role: "assistant", content: "OK, not written." },
    );
    await runTurn(st, "add a reminder", { fetch: f, callTool: y.callTool, confirm: async (n) => { asked.push(n); return false; } });
    assert.deepEqual(asked, ["create_records"]);
    assert.equal(y.calls.length, 0);
    assert.match(seen[1].body.messages.at(-1).content, /^DECLINED/);
    const r2 = replies({ role: "assistant", content: null, tool_calls: [toolCall("w2", "create_records", { table: "Reminders", records: [{ Task: "y" }] })] }, { role: "assistant", content: "Done." });
    await runTurn(st, "add it anyway", { fetch: r2.f, callTool: y.callTool, confirm: async () => true });
    assert.deepEqual(y.calls.map((c) => c.name), ["create_records"]);
    await y.client.close();
  });

  it("unknown tools and bad JSON are answered with an error, not executed", async () => {
    const y = await fakeYgg();
    const st = newState(settings(), pickTools(y.tools, false).picked);
    const { f, seen } = replies(
      { role: "assistant", content: null, tool_calls: [toolCall("u1", "create_records", {}), { id: "u2", type: "function", function: { name: "list_tables", arguments: "{oops" } }] },
      { role: "assistant", content: "sorry" },
    );
    await runTurn(st, "x", { fetch: f, callTool: y.callTool, confirm: async () => true });
    const tm = seen[1].body.messages.filter((m: any) => m.role === "tool").map((m: any) => m.content);
    assert.match(tm[0], /not available in this session/);
    assert.match(tm[1], /not valid JSON/);
    assert.equal(y.calls.length, 0);
    await y.client.close();
  });

  it("stops at the session budget and the round limit", async () => {
    const y = await fakeYgg();
    const st = newState(settings({ MUSE_MAX_TOOL_ROUNDS: "2" }), pickTools(y.tools, false).picked);
    const loop = { role: "assistant", content: null, tool_calls: [toolCall("l", "list_tables", {})] };
    const { f, seen } = replies(loop, loop, { role: "assistant", content: "final" });
    assert.equal(await runTurn(st, "x", { fetch: f, callTool: y.callTool, confirm: async () => true }), "final");
    assert.equal("tools" in seen[2].body, false, "last round offers no tools so Muse must answer");
    const st2 = newState(settings({ MUSE_SESSION_USD: "0" }), pickTools(y.tools, false).picked);
    assert.match(await runTurn(st2, "x", { fetch: f, callTool: y.callTool, confirm: async () => true }), /stopped: session budget/);
    await y.client.close();
  });

  it("reads .env with comments, quotes and export", async () => {
    const { mkdtempSync, writeFileSync, rmSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const d = mkdtempSync(tmpdir() + "/mb-");
    writeFileSync(d + "/.env", "# c\nMODEL_API_KEY='abc def'\nexport MUSE_EFFORT=low   # minimal / low\nMUSE_SYSTEM=\"a # b\"\n");
    const { readEnvFile } = await import("../lib.ts");
    assert.deepEqual(readEnvFile(d + "/.env"), { MODEL_API_KEY: "abc def", MUSE_EFFORT: "low", MUSE_SYSTEM: "a # b" });
    rmSync(d, { recursive: true, force: true });
  });

  it("errors never contain the key", async () => {
    const s = settings();
    const bad = (async () => new Response(JSON.stringify({ error: { message: `nope ${KEY}` } }), { status: 400 })) as unknown as typeof fetch;
    await assert.rejects(chat(s, [], [], bad), (e: Error) => /error 400: nope \[REDACTED\]/.test(e.message) && !e.message.includes(KEY));
    const unauth = (async () => new Response("{}", { status: 401 })) as unknown as typeof fetch;
    await assert.rejects(chat(s, [], [], unauth), /rejected MODEL_API_KEY \(401\)/);
  });
});
