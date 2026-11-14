#!/usr/bin/env node

import { execFile } from "node:child_process";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { homedir } from "node:os";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { randomBytes } from "node:crypto";

import { CommandProtocolError } from "./errors.js";
import { MacOsDialogConfirmationProvider } from "./macos-confirmation.js";
import { LocalScreenshotArtifactSink } from "./receipts.js";
import {
  LauncherService,
  createDemoDriver,
  createLiveDriver,
  liveCapabilities,
  loadLauncherCommands
} from "./launcher-service.js";

const executeFile = promisify(execFile);
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export interface LauncherServerOptions {
  host?: string;
  port?: number;
  assetsDirectory?: string;
  commandsDirectory?: string;
  artifactsDirectory?: string;
  /** Exact proxy hostnames accepted in addition to loopback names. The listener remains local. */
  allowedHosts?: string[];
  service?: LauncherService;
  autoOpen?: boolean;
}

export interface RunningLauncherServer {
  url: string;
  close(): Promise<void>;
}

export async function startLauncherServer(options: LauncherServerOptions = {}): Promise<RunningLauncherServer> {
  const host = options.host ?? "127.0.0.1";
  const assetsDirectory = options.assetsDirectory ?? join(packageRoot, "launcher");
  const commandsDirectory = options.commandsDirectory ?? join(packageRoot, "commands");
  const mode = process.env.IPHONE_LAUNCHER_MODE === "demo" ? "demo" : "live";
  const service = options.service ?? new LauncherService({
    commands: await loadLauncherCommands(commandsDirectory),
    driverFactory: mode === "demo" ? async () => createDemoDriver() : createLiveDriver,
    mode,
    capabilities: liveCapabilities,
    commandsDirectory,
    // The dialog is drawn by macOS, so it only exists where the real mirror does.
    ...(mode === "demo" ? {} : {
      confirmationProvider: new MacOsDialogConfirmationProvider(),
      screenshotArtifactSink: new LocalScreenshotArtifactSink(
        options.artifactsDirectory ?? join(homedir(), "Desktop", "iPhone Command Captures")
      )
    })
  });
  const token = randomBytes(24).toString("base64url");
  const allowedHosts = options.allowedHosts ?? [];

  const server = createServer((request, response) => {
    void handleRequest(request, response, service, assetsDirectory, token, allowedHosts);
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port ?? 4177, host, () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Launcher server did not expose a TCP address");
  const url = `http://${host}:${address.port}`;

  if (options.autoOpen === true) {
    try {
      await executeFile("/usr/bin/open", [url]);
    } catch {
      // The printed URL remains usable if the default browser cannot be opened automatically.
    }
  }
  return {
    url,
    close: () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
  };
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  service: LauncherService,
  assetsDirectory: string,
  token: string,
  allowedHosts: string[]
): Promise<void> {
  securityHeaders(response);
  if (!isAllowedHost(request.headers.host, allowedHosts)) {
    return json(response, 403, { error: { code: "LOCAL_ONLY", message: "Launcher is local or tailnet-only" } });
  }
  const url = new URL(request.url ?? "/", "http://localhost");

  try {
    if (request.method === "GET" && url.pathname === "/api/bootstrap") {
      return json(response, 200, { ...service.status(), authoring: service.canAuthor(), token });
    }
    if (request.method === "POST" && ["/api/author", "/api/save", "/api/update", "/api/delete"].includes(url.pathname)) {
      if (request.headers["x-launcher-token"] !== token) {
        return json(response, 403, { error: { code: "TOKEN_REQUIRED", message: "Refresh the launcher and try again" } });
      }
      const body = await readJson(request);
      const text = typeof body.text === "string" ? body.text : "";
      const commandId = typeof body.commandId === "string" ? body.commandId : undefined;
      if (url.pathname === "/api/author") return json(response, 200, await service.author(text, commandId));
      if (url.pathname === "/api/update") {
        if (!commandId) throw new CommandProtocolError("PARSE_ERROR", "A command must be selected");
        const updated = await service.update(commandId, text);
        return json(response, 200, { updated, commands: service.status().commands });
      }
      if (url.pathname === "/api/delete") {
        if (!commandId) throw new CommandProtocolError("PARSE_ERROR", "A command must be selected");
        await service.delete(commandId);
        return json(response, 200, { deletedCommandId: commandId, commands: service.status().commands });
      }
      // The saved card is returned with the refreshed list so the interface never has to
      // guess what the launcher accepted.
      const saved = await service.save(text);
      return json(response, 200, { saved, commands: service.status().commands });
    }
    if (request.method === "POST" && ["/api/dry-run", "/api/run"].includes(url.pathname)) {
      if (request.headers["x-launcher-token"] !== token) {
        return json(response, 403, { error: { code: "TOKEN_REQUIRED", message: "Refresh the launcher and try again" } });
      }
      const body = await readJson(request);
      const commandId = typeof body.commandId === "string" ? body.commandId : "";
      if (!commandId) throw new CommandProtocolError("PARSE_ERROR", "A command must be selected");
      if (url.pathname === "/api/dry-run") return json(response, 200, await service.dryRun(commandId));
      return json(response, 200, await service.run(commandId));
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json(response, 405, { error: { code: "METHOD_NOT_ALLOWED", message: "Method not allowed" } });
    }
    await serveAsset(response, assetsDirectory, url.pathname, request.method === "HEAD");
  } catch (error) {
    json(response, statusForError(error), { error: publicError(error) });
  }
}

async function serveAsset(response: ServerResponse, directory: string, pathname: string, headOnly: boolean): Promise<void> {
  const requested = pathname === "/" ? "index.html" : pathname.slice(1);
  const relativePath = normalize(requested).replace(/^(\.\.(\/|\\|$))+/, "");
  const path = join(directory, relativePath);
  const info = await stat(path);
  if (!info.isFile()) throw new CommandProtocolError("COMMAND_NOT_FOUND", "Page not found");
  response.statusCode = 200;
  response.setHeader("content-type", contentType(path));
  response.setHeader("content-length", info.size);
  if (headOnly) {
    response.end();
    return;
  }
  createReadStream(path).pipe(response);
}

async function readJson(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > 64 * 1024) throw new CommandProtocolError("PARSE_ERROR", "Request is too large");
    chunks.push(buffer);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("object required");
    return value as Record<string, unknown>;
  } catch {
    throw new CommandProtocolError("PARSE_ERROR", "Request must contain a JSON object");
  }
}

/** A request the launcher understood but refused is the caller's problem, not a server fault. */
function statusForError(error: unknown): number {
  if (!(error instanceof CommandProtocolError)) return 500;
  if (error.code === "COMMAND_NOT_FOUND") return 404;
  const requestFaults = ["PARSE_ERROR", "SCHEMA_INVALID", "UNSUPPORTED_CAPABILITY", "CONFIRMATION_UNAVAILABLE"];
  return requestFaults.includes(error.code) ? 400 : 500;
}

function publicError(error: unknown): { code: string; message: string; setupAction?: string } {
  if (error instanceof CommandProtocolError) {
    const details = error.details as { setupAction?: unknown } | undefined;
    return {
      code: error.code,
      message: error.message,
      ...(typeof details?.setupAction === "string" ? { setupAction: details.setupAction } : {})
    };
  }
  return { code: "LAUNCHER_ERROR", message: error instanceof Error ? error.message : String(error) };
}

function json(response: ServerResponse, status: number, value: unknown): void {
  const body = `${JSON.stringify(value)}\n`;
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.setHeader("content-length", Buffer.byteLength(body));
  response.end(body);
}

function securityHeaders(response: ServerResponse): void {
  response.setHeader("cache-control", "no-store");
  response.setHeader("x-content-type-options", "nosniff");
  response.setHeader("referrer-policy", "no-referrer");
  response.setHeader("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'");
}

function isAllowedHost(host: string | undefined, allowedHosts: string[]): boolean {
  if (!host) return false;
  const name = normalizedHost(host);
  if (name === "127.0.0.1" || name === "localhost" || name === "::1") return true;
  return allowedHosts.some((candidate) => normalizedHost(candidate) === name);
}

function normalizedHost(host: string): string {
  let name = host.trim().toLocaleLowerCase();
  if (name.startsWith("[")) {
    const closingBracket = name.indexOf("]");
    if (closingBracket !== -1) name = name.slice(1, closingBracket);
  } else if (name !== "::1") {
    name = name.replace(/:\d+$/, "");
  }
  return name.replace(/\.$/, "");
}

/** Fail closed to localhost when Tailscale is absent, stopped, or returns an unexpected name. */
export async function discoverTailscaleAllowedHosts(): Promise<string[]> {
  try {
    const result = await executeFile("/usr/local/bin/tailscale", ["status", "--json"], {
      timeout: 3_000,
      maxBuffer: 2 * 1024 * 1024
    });
    const status = JSON.parse(result.stdout) as { Self?: { DNSName?: unknown } };
    if (typeof status.Self?.DNSName !== "string") return [];
    const name = normalizedHost(status.Self.DNSName);
    return /^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.ts\.net$/.test(name) ? [name] : [];
  } catch {
    return [];
  }
}

function contentType(path: string): string {
  const types: Record<string, string> = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml"
  };
  return types[extname(path)] ?? "application/octet-stream";
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  discoverTailscaleAllowedHosts().then((allowedHosts) => startLauncherServer({
    port: Number(process.env.IPHONE_LAUNCHER_PORT ?? 4177),
    autoOpen: process.env.IPHONE_LAUNCHER_NO_OPEN !== "1",
    allowedHosts
  })).then(({ url }) => {
    process.stdout.write(`iPhone Commands is ready at ${url}\n`);
  }).catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
