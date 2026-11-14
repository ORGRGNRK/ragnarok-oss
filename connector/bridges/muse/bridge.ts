#!/usr/bin/env node
// muse-mcp-bridge: let Muse Spark use the Yggdrasil MCP tools.
//   node bridge.ts --list-tools            what Muse would get (no Muse key needed)
//   node bridge.ts                         interactive chat
//   node bridge.ts --ask "question"        one question, then exit
//   --allow-writes                         also offer write tools; each write asks y/N first
// Settings come from ./.env (gitignored) and the environment; see .env.example.
// Secrets (MODEL_API_KEY, the MCP token) are never printed.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { BridgeError, hide, newState, pickTools, readEnvFile, runTurn, settingsFrom, type McpTool, type Settings } from "./lib.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const env: Record<string, string | undefined> = { ...readEnvFile(path.join(here, ".env")), ...process.env };
const argv = process.argv.slice(2);
const flag = (f: string) => argv.includes(f);
const ask = argv.includes("--ask") ? argv[argv.indexOf("--ask") + 1] : undefined;
const expand = (p: string) => p.replace(/^~(?=\/|$)/, homedir());

function mcpToken(): string | undefined {
  if (env.YGG_MCP_TOKEN) return env.YGG_MCP_TOKEN.trim();
  const file = expand(env.YGG_MCP_TOKEN_FILE ?? "~/.config/ragnarok/ygg-mcp-read-token");
  try { return readFileSync(file, "utf8").trim() || undefined; } catch { /* fall through */ }
  if (env.YGG_MCP_TOKEN_CMD) return execFileSync("/bin/sh", ["-c", env.YGG_MCP_TOKEN_CMD], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 20_000 }).trim() || undefined;
  return undefined;
}

let token: string | undefined;

async function connect(): Promise<Client> {
  const client = new Client({ name: "muse-mcp-bridge", version: "0.1.0" });
  if (env.YGG_MCP_COMMAND) {
    const [command, ...args] = env.YGG_MCP_COMMAND.split(" ").filter(Boolean);
    await client.connect(new StdioClientTransport({ command, args, stderr: "ignore" }));
    return client;
  }
  token = mcpToken();
  if (!token) throw new BridgeError("no Yggdrasil MCP token: set YGG_MCP_TOKEN_FILE (default ~/.config/ragnarok/ygg-mcp-read-token) or YGG_MCP_TOKEN_CMD in .env");
  const url = new URL(env.YGG_MCP_URL ?? "https://mcp-server.example.com/mcp");
  await client.connect(new StreamableHTTPClientTransport(url, { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  return client;
}

async function main() {
  const allowWrites = flag("--allow-writes");
  const client = await connect().catch((e) => { throw new BridgeError(`could not connect to Yggdrasil MCP: ${hide((e as Error).message, [token])}`); });
  try {
    const tools = (await client.listTools()).tools as McpTool[];
    const { picked, skipped } = pickTools(tools, allowWrites);
    if (flag("--list-tools")) {
      for (const [name, p] of picked) console.log(`${p.write ? "WRITE" : "read "}  ${name}`);
      for (const s of skipped) console.log(`skip   ${s.name} (${s.why})`);
      console.log(`${tools.length} tools on the server, ${picked.size} offered to Muse`);
      return;
    }
    const base = settingsFrom(env);
    if (!base.apiKey) throw new BridgeError("MODEL_API_KEY is not set. Put MODEL_API_KEY=... in ~/Developer/muse-mcp-bridge/.env (chmod 600). Nothing was sent to Muse.");
    const st = newState(base as Settings, picked);
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const deps = {
      callTool: async (name: string, args: Record<string, unknown>) => {
        const r: any = await client.callTool({ name, arguments: args });
        return { text: (r.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n"), isError: !!r.isError };
      },
      confirm: async (name: string, args: Record<string, unknown>) => {
        console.log(`\nMuse wants to WRITE: ${name}\n${JSON.stringify(args, null, 2)}`);
        return /^y(es)?$/i.test((await rl.question("Allow this write? [y/N] ")).trim());
      },
      log: (l: string) => console.error(`  ${l}`),
    };
    const once = async (q: string) => {
      const a = await runTurn(st, q, deps);
      console.log(`\n${a}\n`);
      console.error(`  [${st.settings.model} ${st.settings.effort} -- session ${st.spent.inTok} in / ${st.spent.outTok} out tokens, ~$${st.spent.usd.toFixed(4)} of $${st.settings.sessionBudgetUsd.toFixed(2)}]`);
    };
    console.error(`Connected: ${picked.size} Yggdrasil tools for ${st.settings.model} (${allowWrites ? "writes allowed, each confirmed" : "read-only"}). actor "${st.settings.actor}", session ${st.settings.session}`);
    if (ask) await once(ask);
    else for (;;) {
      const q = (await rl.question("you> ")).trim();
      if (!q || q === "/quit" || q === "/exit") break;
      await once(q);
    }
    rl.close();
  } finally {
    await client.close().catch(() => {});
  }
}

main().catch((e) => {
  console.error(`muse-mcp-bridge: ${hide(e instanceof Error ? e.message : String(e), [env.MODEL_API_KEY, token])}`);
  process.exit(1);
});
