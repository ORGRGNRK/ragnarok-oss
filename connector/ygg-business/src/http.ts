#!/usr/bin/env node
/**
 * Entry point: Secure MCP Platform over Streamable HTTP (stateless JSON mode).
 * Includes hardware presence unlock endpoints (/unlock, /lock, /status) for companion apps
 * and host unlock scripts.
 *
 *   PLATFORM_HTTP_PORT          default 8787
 *   PLATFORM_HTTP_HOST          default 127.0.0.1 (0.0.0.0 in containers)
 *   PLATFORM_HTTP_ALLOWED_HOSTS default "127.0.0.1,localhost,rgnrk.co,*.rgnrk.co"
 *   PLATFORM_BEARER_TOKENS      optional comma-separated tokens
 */
import http from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { Pool } from "./core/db.js";
import { createRedactor, type Redactor } from "./core/redact.js";
import { createPlatformRuntime } from "./platform/app.js";
import { loadPlatformConfig } from "./platform/config.js";

const MAX_BODY = 1_000_000;

function clientAddr(req: http.IncomingMessage): string {
  const cf = req.headers["cf-connecting-ip"];
  if (typeof cf === "string" && cf.trim()) return cf.trim();
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.trim()) return fwd.split(",")[0]?.trim() || "unknown";
  return req.socket.remoteAddress || "unknown";
}

interface AuthIdentity {
  name: string;
  type: "bearer" | "cloudflare" | "local";
}

function parseTokenRules(raw: string | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (!raw) return map;
  for (const part of raw.split(",")) {
    const item = part.trim();
    if (!item) continue;
    const colon = item.indexOf(":");
    if (colon > 0) {
      const label = item.slice(0, colon).trim();
      const token = item.slice(colon + 1).trim();
      if (label && token) map.set(token, label);
    } else {
      map.set(item, "bearer-token");
    }
  }
  return map;
}

function authenticate(req: http.IncomingMessage, tokenRules: Map<string, string>, authRequired: boolean): AuthIdentity | null {
  const cfUser = req.headers["cf-access-authenticated-user-email"];
  if (typeof cfUser === "string" && cfUser.trim()) {
    return { name: cfUser.trim(), type: "cloudflare" };
  }

  const authHeader = req.headers.authorization;
  if (typeof authHeader === "string" && authHeader.startsWith("Bearer ")) {
    const token = authHeader.slice(7).trim();
    if (tokenRules.size === 0) return { name: "bearer", type: "bearer" };
    const label = tokenRules.get(token);
    if (label) return { name: label, type: "bearer" };
    return null;
  }

  if (!authRequired) {
    return { name: "anonymous", type: "local" };
  }

  return null;
}

async function logTransport(
  pool: Pool,
  redactor: Redactor,
  clientIp: string,
  method: string,
  path: string,
  statusCode: number,
  tokenLabel: string | null,
  durationMs: number,
  errorMessage?: string,
): Promise<void> {
  try {
    await pool.query(
      `INSERT INTO public.transport_log (client_ip, method, path, status_code, token_label, duration_ms, error_message)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        clientIp,
        method,
        path,
        statusCode,
        tokenLabel,
        Math.round(durationMs),
        errorMessage ? redactor.text(errorMessage) : null,
      ],
    );
  } catch {
    // Non-fatal audit log failure
  }
}

async function main(): Promise<void> {
  let log = (msg: string) => process.stderr.write(`[secure-mcp-platform:http] ${createRedactor().text(msg)}\n`);
  const cfg = loadPlatformConfig();
  const rt = createPlatformRuntime(cfg, (m) => log(m));
  log = (msg: string) => process.stderr.write(`[secure-mcp-platform:http] ${rt.redactor.text(msg)}\n`);

  const port = Number(process.env.PLATFORM_HTTP_PORT || process.env.BUSINESS_HTTP_PORT || 8787);
  const bind = process.env.PLATFORM_HTTP_HOST || process.env.BUSINESS_HTTP_HOST || "127.0.0.1";
  const authRequired = (process.env.PLATFORM_HTTP_AUTH_REQUIRED || process.env.BUSINESS_HTTP_AUTH_REQUIRED) === "true";
  const tokenRules = parseTokenRules(process.env.PLATFORM_BEARER_TOKENS || process.env.BUSINESS_BEARER_TOKENS);

  const allowed = new Set(
    (process.env.PLATFORM_HTTP_ALLOWED_HOSTS || process.env.BUSINESS_HTTP_ALLOWED_HOSTS || "127.0.0.1,localhost,rgnrk.co,*.rgnrk.co")
      .split(",")
      .map((h) => h.trim().toLowerCase())
      .filter(Boolean),
  );

  const hostOk = (h: string | undefined) => {
    if (!h) return false;
    const clean = h.toLowerCase().replace(/:\d+$/, "").replace(/^\[|\]$/g, "");
    if (allowed.has(clean) || allowed.has("*")) return true;
    for (const pattern of allowed) {
      if (pattern.startsWith("*.") && clean.endsWith(pattern.slice(1))) return true;
    }
    return false;
  };

  const send = (res: http.ServerResponse, code: number, body: unknown) => {
    res.writeHead(code, { "content-type": "application/json" }).end(JSON.stringify(body));
  };

  const readBody = async (req: http.IncomingMessage): Promise<any> => {
    let size = 0;
    const chunks: Buffer[] = [];
    for await (const c of req) {
      size += (c as Buffer).length;
      if (size > MAX_BODY) throw new Error("Body too large");
      chunks.push(c as Buffer);
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    return raw ? JSON.parse(raw) : {};
  };

  const server = http.createServer(async (req, res) => {
    const start = performance.now();
    const path = (req.url || "/").split("?")[0] || "/";
    const ip = clientAddr(req);
    let tokenName: string | null = null;
    let errText: string | undefined;

    const originalEnd = res.end.bind(res);
    res.end = ((...args: unknown[]) => {
      const duration = performance.now() - start;
      void logTransport(rt.appPool, rt.redactor, ip, req.method || "GET", path, res.statusCode, tokenName, duration, errText);
      return (originalEnd as Function)(...args);
    }) as any;

    try {
      if ((path === "/health" || path === "/healthz") && req.method === "GET") {
        return send(res, 200, { ok: true });
      }

      // Hardware Security Gate Status
      if ((path === "/status" || path === "/api/status") && req.method === "GET") {
        return send(res, 200, {
          platform: "secure-mcp-platform",
          ...rt.securityGate.getStatus(),
        });
      }

      // Unlock Platform via YubiKey / Secure Enclave
      if ((path === "/unlock" || path === "/api/unlock") && req.method === "POST") {
        const payload = await readBody(req);
        const method = payload.method === "secure_enclave" ? "secure_enclave" : "yubikey";
        const proof = payload.secret || payload.token || req.headers["x-unlock-secret"];
        try {
          const result = rt.securityGate.unlock(method, proof);
          return send(res, 200, {
            ok: true,
            message: `Platform unlocked via ${method}`,
            expires_at: result.expiresAt.toISOString(),
            status: rt.securityGate.getStatus(),
          });
        } catch (err) {
          return send(res, 401, {
            ok: false,
            error: "Unauthorized: Invalid hardware authorization secret or proof",
            status: rt.securityGate.getStatus(),
          });
        }
      }

      // Lock Platform
      if ((path === "/lock" || path === "/api/lock") && req.method === "POST") {
        rt.securityGate.lock();
        return send(res, 200, {
          ok: true,
          message: "Platform locked",
          status: rt.securityGate.getStatus(),
        });
      }

      if (path !== "/mcp") {
        errText = "Not found";
        return send(res, 404, { error: errText });
      }

      if (!hostOk(req.headers.host)) {
        errText = "Host not allowed";
        return send(res, 403, { error: errText });
      }

      if (req.method !== "POST") {
        errText = "Method not allowed (stateless server: POST only)";
        return send(res, 405, { jsonrpc: "2.0", error: { code: -32000, message: errText }, id: null });
      }

      const who = authenticate(req, tokenRules, authRequired);
      if (!who) {
        errText = "Unauthorized";
        return send(res, 401, { jsonrpc: "2.0", error: { code: -32001, message: "Unauthorized" }, id: null });
      }
      tokenName = who.name;

      const body = await readBody(req);
      const acc = req.headers.accept || "";
      if (!acc.includes("application/json") || !acc.includes("text/event-stream")) {
        req.headers.accept = "application/json, text/event-stream";
      }
      const mcp = rt.host.createServer();
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      res.on("close", () => {
        void transport.close();
        void mcp.close();
      });
      await mcp.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (err) {
      errText = (err as Error).message;
      log(`request failed: ${errText}`);
      if (!res.headersSent) {
        send(res, 500, { jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null });
      }
    }
  });

  let closing = false;
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    server.close();
    await rt.host.drain(cfg.searchTimeoutMs);
    await rt.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  server.listen(port, bind, () =>
    log(`ready on http://${bind}:${port}/mcp (locked=${rt.securityGate.isLocked()}, embedder ${cfg.embedderModel} at ${cfg.embedderUrl})`),
  );
}

main().catch((err) => {
  process.stderr.write(`[secure-mcp-platform:http] fatal: ${createRedactor().text((err as Error).message)}\n`);
  process.exit(1);
});
