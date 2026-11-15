#!/usr/bin/env node
// Remote transport: MCP "streamable HTTP" at POST /mcp, protected by a bearer token.
//   MCP_TOKEN       full access (read + write tools), unless KIT_SCOPE=read caps the server
//   MCP_READ_TOKEN  read-only: write tools hidden, database login is the read-only user
// Tokens come from .env, are compared in constant time, and are never logged or echoed.
// GET /health answers {"ok":true} without a token (for uptime checks); it reveals nothing else.
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { env, serverScope, type Scope } from "./config.js";
import { closeDb, scrub } from "./db.js";
import { handleIntake } from "./intake.js";
import { handleReceipts } from "./agentlog.js";
import { loadSchema } from "./schema.js";
import { buildServer } from "./server.js";

const MIN_TOKEN = 32;
const MAX_BODY = 1_000_000;
const digest = (s: string) => createHash("sha256").update(s, "utf8").digest();

// RECEIPT_TOKEN can only add AI activity receipts (POST /receipts): no tools, no data.
interface TokenRule { name: string; scope: Scope | "receipts"; hash: Buffer }
function tokenRules(): TokenRule[] {
  const e = env(); const cap = serverScope(); const rules: TokenRule[] = [];
  const add = (name: string, value: string | undefined, scope: Scope | "receipts") => {
    if (!value) return;
    if (value.length < MIN_TOKEN || /CHANGE-ME/.test(value)) throw new Error(`${name} is too short or still a placeholder (need ${MIN_TOKEN}+ random characters)`);
    rules.push({ name, scope: scope === "receipts" ? "receipts" : cap === "read" ? "read" : scope, hash: digest(value) });
  };
  add("MCP_TOKEN", e.MCP_TOKEN, "write");
  add("MCP_READ_TOKEN", e.MCP_READ_TOKEN, "read");
  add("RECEIPT_TOKEN", e.RECEIPT_TOKEN, "receipts");
  if (!rules.some((r) => r.scope !== "receipts")) throw new Error("no MCP_TOKEN or MCP_READ_TOKEN set: refusing to start an unprotected HTTP server");
  return rules;
}

function authenticate(req: IncomingMessage, rules: TokenRule[]): TokenRule | undefined {
  const h = req.headers.authorization;
  if (typeof h !== "string") return undefined;
  const m = /^Bearer\s+(\S+)\s*$/i.exec(h);
  if (!m) return undefined;
  const got = digest(m[1]);
  let hit: TokenRule | undefined;
  for (const r of rules) if (timingSafeEqual(got, r.hash)) hit = r;   // check all, no early exit
  return hit;
}

// Who is calling, for logs and receipts. CF-Connecting-IP / X-Forwarded-For can be typed by anyone, so they
// are only believed when TRUST_PROXY_HEADERS=1 (set it when a Cloudflare tunnel or proxy is in front).
const trustProxy = () => env().TRUST_PROXY_HEADERS === "1";
function clientAddr(req: IncomingMessage): string {
  const sock = req.socket.remoteAddress || "?";
  if (!trustProxy()) return sock;
  const cf = req.headers["cf-connecting-ip"];
  const xff = req.headers["x-forwarded-for"];
  return (typeof cf === "string" && cf) || (typeof xff === "string" && xff.split(",")[0].trim()) || sock;
}

// Too many bad tokens from one address -> that address is refused (429) for a while, even with a good token.
// AUTH_FAIL_LIMIT failures within AUTH_FAIL_WINDOW_S seconds -> blocked for AUTH_BLOCK_S seconds.
const fails = new Map<string, { n: number; first: number; until: number }>();
const num = (k: string, d: number) => { const n = Number(env()[k]); return Number.isFinite(n) && n > 0 ? n : d; };
function blocked(addr: string): number {
  const f = fails.get(addr); const now = Date.now();
  if (!f) return 0;
  if (f.until > now) return Math.ceil((f.until - now) / 1000);
  if (now - f.first > num("AUTH_FAIL_WINDOW_S", 300) * 1000) fails.delete(addr);
  return 0;
}
function noteFail(addr: string) {
  const now = Date.now(); const win = num("AUTH_FAIL_WINDOW_S", 300) * 1000;
  let f = fails.get(addr);
  if (!f || now - f.first > win) f = { n: 0, first: now, until: 0 };
  f.n++;
  if (f.n >= num("AUTH_FAIL_LIMIT", 10)) { f.until = now + num("AUTH_BLOCK_S", 900) * 1000; console.error(`[client-kit] blocking ${addr} for ${num("AUTH_BLOCK_S", 900)}s after ${f.n} bad tokens`); }
  fails.set(addr, f);
  if (fails.size > 10_000) for (const [k, v] of fails) if (v.until < now && now - v.first > win) fails.delete(k);
}

function sendJson(res: ServerResponse, status: number, body: unknown, extra: Record<string, string> = {}) {
  res.writeHead(status, { "content-type": "application/json", ...extra });
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []; let n = 0;
  for await (const c of req) { n += (c as Buffer).length; if (n > MAX_BODY) throw new Error("body too large"); chunks.push(c as Buffer); }
  const s = Buffer.concat(chunks).toString("utf8");
  return s ? JSON.parse(s) : undefined;
}

async function main() {
  loadSchema();
  const rules = tokenRules();
  const port = Number(env().MCP_HTTP_PORT || 8787);
  const host = env().MCP_HTTP_HOST || "0.0.0.0";

  const http = createServer(async (req, res) => {
    const path = (req.url || "/").split("?")[0];
    try {
      if (path === "/health" && req.method === "GET") return sendJson(res, 200, { ok: true });
      const addr = clientAddr(req);
      const wait = (path.startsWith("/intake") || path === "/mcp" || path === "/receipts") ? blocked(addr) : 0;
      if (wait) return sendJson(res, 429, { error: "Too many failed sign-ins from this address; try again later" }, { "retry-after": String(wait) });
      if (path === "/receipts") {
        const who = authenticate(req, rules);
        if (!who) {
          noteFail(addr);
          console.error(`[client-kit] refused ${req.method} /receipts from ${addr}: ${req.headers.authorization ? "bad token" : "no token"}`);
          return sendJson(res, 401, { error: "Unauthorized: send Authorization: Bearer <RECEIPT_TOKEN>" }, { "www-authenticate": 'Bearer realm="client-kit"' });
        }
        if (who.scope === "read") return sendJson(res, 403, { error: "the read-only token can't add receipts" });
        let body: unknown;
        try { body = await readBody(req); } catch { return sendJson(res, 400, { error: "body is not JSON or is too large" }); }
        return handleReceipts(req, res, body, `receipts:${who.name === "MCP_TOKEN" ? "write-token" : "receipt-token"}@${addr}`);
      }
      if (path.startsWith("/intake")) {
        const who = authenticate(req, rules);
        if (!who) {
          noteFail(addr);
          console.error(`[client-kit] refused ${req.method} ${path} from ${clientAddr(req)}: ${req.headers.authorization ? "bad token" : "no token"}`);
          return sendJson(res, 401, { error: "Unauthorized: send Authorization: Bearer <token>" }, { "www-authenticate": 'Bearer realm="client-kit"' });
        }
        if (who.scope === "receipts") return sendJson(res, 403, { error: "the receipt token can only add receipts (POST /receipts)" });
        const via = `intake:${who.name === "MCP_TOKEN" ? "write-token" : "read-token"}@${clientAddr(req)}`;
        return handleIntake(req, res, who.scope as Scope, via);
      }
      if (path !== "/mcp") return sendJson(res, 404, { error: "not found" });
      const who = authenticate(req, rules);
      if (!who) {
        noteFail(addr);
        console.error(`[client-kit] refused ${req.method} /mcp from ${clientAddr(req)}: ${req.headers.authorization ? "bad token" : "no token"}`);
        return sendJson(res, 401, { jsonrpc: "2.0", error: { code: -32001, message: "Unauthorized: send Authorization: Bearer <token>" }, id: null }, { "www-authenticate": 'Bearer realm="client-kit"' });
      }
      if (who.scope === "receipts") return sendJson(res, 403, { jsonrpc: "2.0", error: { code: -32001, message: "the receipt token can only add receipts (POST /receipts)" }, id: null });
      if (req.method !== "POST") return sendJson(res, 405, { jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed (stateless server: POST only)" }, id: null }, { allow: "POST" });
      let body: unknown;
      try { body = await readBody(req); } catch { return sendJson(res, 400, { jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: null }); }
      // Stateless: a fresh MCP server per request, scoped by the token that was presented.
      const via = `http:${who.name === "MCP_TOKEN" ? "write-token" : "read-token"}@${clientAddr(req)}`;
      const server = buildServer(who.scope as Scope, via, `http-${randomUUID().slice(0, 8)}`);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      res.on("close", () => { transport.close().catch(() => undefined); server.close().catch(() => undefined); });
      await server.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (e) {
      console.error(`[client-kit] request error: ${scrub(e)}`);
      if (!res.headersSent) sendJson(res, 500, { jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null });
    }
  });
  if (process.env.INTAKE_BLOB_DIR) {
    http.requestTimeout = 0;
    http.headersTimeout = 120_000;
    http.timeout = 0;
  }
  http.listen(port, host, () => {
    console.error(`[client-kit] http ready on ${host}:${port}/mcp -- tokens: ${rules.map((r) => `${r.name}=>${r.scope}`).join(", ")} (values never logged)`);
  });
  const stop = () => { http.close(); closeDb().finally(() => process.exit(0)); };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
main().catch((e) => { console.error(`[client-kit] FATAL: ${scrub(e)}`); process.exit(1); });
