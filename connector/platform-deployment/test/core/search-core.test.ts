import { createServer, type Server } from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { OllamaEmbedder } from "../../src/core/search/embedder.js";
import { cosine } from "../../src/core/search/vector-index.js";

describe("cosine", () => {
  it("scores identical, orthogonal and zero vectors", () => {
    expect(cosine([1, 2], [2, 4])).toBeCloseTo(1);
    expect(cosine([1, 0], [0, 1])).toBe(0);
    expect(cosine([0, 0], [1, 1])).toBe(0);
  });
});

describe("OllamaEmbedder", () => {
  let srv: Server;
  let url = "";
  const seen: any[] = [];
  beforeAll(async () => {
    srv = createServer((req, res) => {
      let body = "";
      req.on("data", (d) => (body += d));
      req.on("end", () => {
        const j = JSON.parse(body);
        seen.push(j);
        if (j.model === "missing") { res.writeHead(404).end('{"error":"model not found"}'); return; }
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ embedding: [1, 0, 0.5] }));
      });
    });
    await new Promise<void>((r) => srv.listen(0, "127.0.0.1", r));
    url = `http://127.0.0.1:${(srv.address() as any).port}`;
  });
  afterAll(() => new Promise<void>((r) => srv.close(() => r())));

  it("calls /api/embeddings and adds nomic task prefixes", async () => {
    const e = new OllamaEmbedder({ baseUrl: url + "/", model: "nomic-embed-text" });
    expect(await e.embed(["a phone"], "document")).toEqual([[1, 0, 0.5]]);
    await e.embed(["phone"], "query");
    expect(seen[0]).toEqual({ model: "nomic-embed-text", prompt: "search_document: a phone" });
    expect(seen[1].prompt).toBe("search_query: phone");
  });

  it("fails: embedder unreachable gives a retry-safe upstream_unavailable error", async () => {
    const e = new OllamaEmbedder({ baseUrl: "http://127.0.0.1:9", model: "nomic-embed-text", timeoutMs: 2000 });
    await expect(e.embed(["x"], "query")).rejects.toMatchObject({ code: "upstream_unavailable", retry_safe: true });
  });

  it("fails: missing model tells the operator to pull it", async () => {
    const e = new OllamaEmbedder({ baseUrl: url, model: "missing" });
    await expect(e.embed(["x"], "query")).rejects.toMatchObject({ fix: expect.stringMatching(/ollama pull missing/) });
  });
});
