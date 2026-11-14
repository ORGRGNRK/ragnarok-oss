import { createHash } from "node:crypto";
import type { EmbedKind, Embedder } from "../../src/core/search/embedder.js";

/**
 * Deterministic offline embedder: hashed bag-of-words into `dims` buckets.
 * Shared words give high cosine similarity, which is enough to test ranking.
 */
export class StubEmbedder implements Embedder {
  documentsEmbedded = 0;
  queriesEmbedded = 0;

  constructor(readonly model = "stub-embedder", private readonly dims = 64) {}

  async embed(texts: string[], kind: EmbedKind): Promise<number[][]> {
    if (kind === "document") this.documentsEmbedded += texts.length;
    else this.queriesEmbedded += texts.length;
    return texts.map((t) => this.vector(t));
  }

  private vector(t: string): number[] {
    const v = new Array<number>(this.dims).fill(0);
    for (const w of t.toLowerCase().match(/[a-z0-9]+/g) ?? []) {
      const b = createHash("md5").update(w).digest().readUInt32BE(0) % this.dims;
      v[b] = (v[b] ?? 0) + 1;
    }
    return v;
  }
}
