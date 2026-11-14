import { describe, expect, it } from "vitest";
import { TokenBucket } from "../../src/core/rate-limit.js";
import { MemoryReceiptSink } from "../../src/core/receipts.js";
import { createRedactor } from "../../src/core/redact.js";
import { defineTool, ToolHost, type ToolDef } from "../../src/core/server.js";
import { z } from "../../src/core/validate.js";

function host(receipts: MemoryReceiptSink) {
  const tools = [
    defineTool({
      name: "demo_get_wait",
      description: "Resolves after 100 ms.",
      input: z.object({}).strict(),
      handler: () => new Promise((res) => setTimeout(() => res({ summary: "done", data: {} }), 100)),
    }),
  ] as unknown as ToolDef[];
  return new ToolHost({
    name: "demo", version: "0", tools,
    limiter: new TokenBucket({ capacity: 10, refillPerSecond: 10 }),
    receipts, redactor: createRedactor([]), defaultTimeoutMs: 5000, log: () => {},
  });
}

describe("ToolHost.drain (shutdown)", () => {
  it("waits for an in-flight call and its receipt before returning", async () => {
    const receipts = new MemoryReceiptSink();
    const h = host(receipts);
    const call = h.call("demo_get_wait", {});
    await h.drain(5000);
    expect(receipts.rows.length).toBe(1);
    expect((await call).isError).toBeFalsy();
  });

  it("returns at once when idle, and gives up after its timeout", async () => {
    const h = host(new MemoryReceiptSink());
    const t0 = Date.now();
    await h.drain(5000);
    expect(Date.now() - t0).toBeLessThan(50);
    void h.call("demo_get_wait", {});
    const t1 = Date.now();
    await h.drain(10);
    expect(Date.now() - t1).toBeLessThan(90);
  });
});
