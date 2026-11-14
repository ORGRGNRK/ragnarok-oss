import { ToolError } from "../errors.js";

export type EmbedKind = "document" | "query";

export interface Embedder {
  /** Model name; also the key under which vectors and index state are stored. */
  readonly model: string;
  embed(texts: string[], kind: EmbedKind, signal?: AbortSignal): Promise<number[][]>;
}

export interface OllamaEmbedderOptions {
  /** Base URL of an Ollama-compatible API, e.g. http://127.0.0.1:11434 */
  baseUrl: string;
  model: string;
  /** Per-request timeout. */
  timeoutMs?: number;
}

/**
 * Client for the Ollama embeddings API (POST /api/embeddings {model, prompt}).
 * nomic-embed-text expects task prefixes; they are added automatically for
 * nomic models so stored documents and queries live in the same space.
 */
export class OllamaEmbedder implements Embedder {
  readonly model: string;
  private readonly base: string;
  private readonly timeoutMs: number;
  private readonly nomic: boolean;

  constructor(opts: OllamaEmbedderOptions) {
    this.model = opts.model;
    this.base = opts.baseUrl.replace(/\/+$/, "");
    this.timeoutMs = opts.timeoutMs ?? 15_000;
    this.nomic = /^nomic-embed/i.test(opts.model);
  }

  private prefix(kind: EmbedKind): string {
    if (!this.nomic) return "";
    return kind === "query" ? "search_query: " : "search_document: ";
  }

  async embed(texts: string[], kind: EmbedKind, signal?: AbortSignal): Promise<number[][]> {
    const out: number[][] = [];
    for (const t of texts) out.push(await this.one(this.prefix(kind) + t, signal));
    return out;
  }

  private async one(prompt: string, outer?: AbortSignal): Promise<number[]> {
    const url = `${this.base}/api/embeddings`;
    const signal = outer ? AbortSignal.any([outer, AbortSignal.timeout(this.timeoutMs)]) : AbortSignal.timeout(this.timeoutMs);
    let res: Response;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: this.model, prompt }),
        signal,
      });
    } catch (err) {
      const c = (err as { cause?: { code?: string; errors?: Array<{ code?: string }> } })?.cause;
      const cause =
        c?.code ?? c?.errors?.[0]?.code ?? ((err as Error)?.name === "TimeoutError" ? "timed out" : (err as Error)?.name) ?? "fetch failed";
      throw new ToolError({
        code: "upstream_unavailable",
        what: "the embedder could not be reached",
        why: `no answer from ${this.base} for model ${this.model} (${cause})`,
        retry_safe: true,
        fix: `start an Ollama-compatible embedder at ${this.base} with model ${this.model} pulled (or set the embedder URL/model config), then retry; retry is safe because search is read-only`,
      });
    }
    if (!res.ok) {
      const body = (await res.text().catch(() => "")).slice(0, 200);
      throw new ToolError({
        code: "upstream_unavailable",
        what: "the embedder returned an error",
        why: `HTTP ${res.status} from ${url}${body ? `: ${body}` : ""}`,
        retry_safe: true,
        fix: res.status === 404 ? `pull the model first (ollama pull ${this.model}), then retry` : "check the embedder logs, then retry",
      });
    }
    const json = (await res.json().catch(() => null)) as { embedding?: unknown } | null;
    const v = json?.embedding;
    if (!Array.isArray(v) || v.length === 0 || !v.every((x) => typeof x === "number")) {
      throw new ToolError({
        code: "upstream_unavailable",
        what: "the embedder returned no usable vector",
        why: `response from ${url} had no numeric "embedding" array`,
        retry_safe: true,
        fix: `confirm ${this.model} is an embedding model and the URL points at the Ollama API, then retry`,
      });
    }
    return v as number[];
  }
}
