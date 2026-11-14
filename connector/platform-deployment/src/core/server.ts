/**
 * Tool registry and dispatcher shared by every project MCP.
 *
 * A request flows: tools/call -> lookup (unknown name = protocol error)
 * -> rate limiter -> zod validation -> handler under a timeout
 * -> result { content: [text summary], structuredContent } or ToolError result
 * -> receipt row (redacted args, ok flag, error code, duration).
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
  type Tool,
  type ToolAnnotations,
} from "@modelcontextprotocol/sdk/types.js";
import { mapDatabaseError, ToolError, unknownToolError } from "./errors.js";
import type { TokenBucket } from "./rate-limit.js";
import type { ReceiptSink } from "./receipts.js";
import type { Redactor } from "./redact.js";
import { withTimeout } from "./timeout.js";
import { toInputSchema, validateArgs, type z } from "./validate.js";

export interface ToolOutput {
  /** One short human-readable line. */
  summary: string;
  /** Structured result; always a JSON object. */
  data: Record<string, unknown>;
}

export interface ToolDef<S extends z.ZodObject = z.ZodObject> {
  name: string;
  title?: string;
  description: string;
  input: S;
  annotations?: ToolAnnotations;
  /** Allow calling this tool even when the platform security gate is locked. */
  allowWhileLocked?: boolean;
  /** Overrides the server default timeout for slow tools (e.g. search with indexing). */
  timeoutMs?: number;
  handler: (args: z.infer<S>, ctx: { signal: AbortSignal }) => Promise<ToolOutput>;
}

/** Identity helper that keeps handler argument types inferred from the schema. */
export function defineTool<S extends z.ZodObject>(def: ToolDef<S>): ToolDef<S> {
  return def;
}

export interface SecurityGateLike {
  isLocked(): boolean;
}

export interface ToolHostOptions {
  name: string;
  version: string;
  tools: ToolDef[];
  limiter: TokenBucket;
  receipts: ReceiptSink;
  redactor: Redactor;
  defaultTimeoutMs: number;
  securityGate?: SecurityGateLike;
  instructions?: string;
  log?: (msg: string) => void;
}

const NAME_RULE = /^[a-z][a-z0-9]*_(list|get|search|summarize|status|lock|unlock)(_[a-z0-9_]+)?$/;

export class ToolHost {
  private readonly byName = new Map<string, ToolDef>();
  private readonly listing: Tool[];
  private readonly inflight = new Set<Promise<unknown>>();

  constructor(private readonly opts: ToolHostOptions) {
    for (const t of opts.tools) {
      if (!NAME_RULE.test(t.name)) throw new Error(`tool name "${t.name}" must be prefix_verb_noun (verb: list|get|search|summarize)`);
      if (this.byName.has(t.name)) throw new Error(`duplicate tool ${t.name}`);
      this.byName.set(t.name, t);
    }
    this.listing = opts.tools.map((t) => ({
      name: t.name,
      ...(t.title ? { title: t.title } : {}),
      description: t.description,
      inputSchema: toInputSchema(t.input),
      ...(t.annotations ? { annotations: t.annotations } : {}),
    }));
  }

  listTools(): Tool[] {
    return this.listing;
  }

  /** Dispatch one call. Throws McpError only for protocol-level problems. */
  call(name: string, args: unknown): Promise<CallToolResult> {
    const p = this.dispatch(name, args);
    this.inflight.add(p);
    const done = () => this.inflight.delete(p);
    p.then(done, done);
    return p;
  }

  /** Wait (up to timeoutMs) for calls already in progress, e.g. before closing pools on shutdown. */
  async drain(timeoutMs = 10_000): Promise<void> {
    if (this.inflight.size === 0) return;
    let timer: NodeJS.Timeout | undefined;
    const limit = new Promise<void>((r) => { timer = setTimeout(r, timeoutMs); });
    await Promise.race([Promise.allSettled([...this.inflight]).then(() => undefined), limit]);
    clearTimeout(timer);
  }

  private async dispatch(name: string, args: unknown): Promise<CallToolResult> {
    const tool = this.byName.get(name);
    if (!tool) throw unknownToolError(name, [...this.byName.keys()]);

    const started = performance.now();
    let result: CallToolResult;
    let errorCode: string | null = null;
    try {
      if (this.opts.securityGate?.isLocked() && !tool.allowWhileLocked) {
        throw new ToolError({
          code: "locked",
          what: `${name} rejected`,
          why: "Docker platform is locked. Physical hardware presence (YubiKey touch or Apple Secure Enclave) is required.",
          retry_safe: true,
          fix: "Unlock via ./unlock.sh or invoke platform_unlock.",
        });
      }
      this.opts.limiter.take(`${name} was not run`);
      const parsed = validateArgs(name, tool.input, args);
      const out = await withTimeout(`${name} timed out`, tool.timeoutMs ?? this.opts.defaultTimeoutMs, async (signal) => {
        if (this.opts.receipts.executeWithReceipt) {
          return await this.opts.receipts.executeWithReceipt(name, args, () => tool.handler(parsed, { signal }));
        }
        return await tool.handler(parsed, { signal });
      });
      result = {
        content: [{ type: "text", text: this.opts.redactor.text(out.summary) }],
        structuredContent: this.opts.redactor.value(out.data),
      };
    } catch (err) {
      const te = err instanceof ToolError ? err : mapDatabaseError(err, `${name} failed`);
      errorCode = te.code;
      const safe = this.opts.redactor.value(te.toJSON());
      result = {
        isError: true,
        content: [{ type: "text", text: this.opts.redactor.text(te.toText()) }],
        structuredContent: { error: safe },
      };
      if (te.code === "internal") this.opts.log?.(this.opts.redactor.text(`[${name}] ${(err as Error)?.stack ?? String(err)}`));
    }
    if (result.isError || (this.opts.receipts as any).rows !== undefined) {
      await this.opts.receipts.write({
        tool: name,
        args,
        ok: !result.isError,
        error_code: errorCode,
        duration_ms: performance.now() - started,
      });
    }
    return result;
  }

  /** Build an SDK Server exposing this host's tools (tools capability only). */
  createServer(): Server {
    const server = new Server(
      { name: this.opts.name, version: this.opts.version },
      { capabilities: { tools: {} }, ...(this.opts.instructions ? { instructions: this.opts.instructions } : {}) },
    );
    server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: this.listTools() }));
    server.setRequestHandler(CallToolRequestSchema, async (req) => this.call(req.params.name, req.params.arguments));
    return server;
  }
}
