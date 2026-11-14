import { describe, expect, it } from "vitest";
import { decodeCursor, encodeCursor } from "../../src/core/cursor.js";
import { ToolError } from "../../src/core/errors.js";
import { TokenBucket } from "../../src/core/rate-limit.js";
import { withTimeout } from "../../src/core/timeout.js";
import { toInputSchema, validateArgs, z } from "../../src/core/validate.js";

const schema = z.object({ q: z.string().min(1), limit: z.number().int().min(1).max(10).default(5) }).strict();

describe("validation", () => {
  it("applies defaults and returns typed args", () => {
    expect(validateArgs("t", schema, { q: "x" })).toEqual({ q: "x", limit: 5 });
  });

  it("produces an object JSON Schema with constraints", () => {
    const js = toInputSchema(schema);
    expect(js.type).toBe("object");
    expect(js.required).toEqual(["q"]);
    expect((js.properties as any).limit.maximum).toBe(10);
  });

  it("fails: rejects bad input with an actionable invalid_argument error", () => {
    try {
      validateArgs("t", schema, { q: 3, limit: 99, extra: 1 });
      expect.unreachable();
    } catch (e) {
      const te = e as ToolError;
      expect(te.code).toBe("invalid_argument");
      expect(te.why).toMatch(/q:/);
      expect(te.why).toMatch(/limit:/);
      expect(te.retry_safe).toBe(true);
    }
  });
});

describe("timeout", () => {
  it("returns the value when work finishes in time", async () => {
    await expect(withTimeout("w", 200, async () => 42)).resolves.toBe(42);
  });

  it("fails: raises a retry-safe timeout ToolError and aborts the signal", async () => {
    let aborted = false;
    const p = withTimeout("slow thing", 30, (signal) => new Promise((res) => {
      signal.addEventListener("abort", () => { aborted = true; });
      setTimeout(res, 500);
    }));
    await expect(p).rejects.toMatchObject({ code: "timeout", retry_safe: true });
    expect(aborted).toBe(true);
  });
});

describe("rate limiter", () => {
  it("allows a burst then refills over time", () => {
    let t = 0;
    const b = new TokenBucket({ capacity: 2, refillPerSecond: 1, now: () => t });
    b.take("a");
    b.take("a");
    expect(() => b.take("a")).toThrow(ToolError);
    t += 1000;
    expect(() => b.take("a")).not.toThrow();
  });

  it("fails: rate limit exceeded gives retry_after_ms and retry_safe", () => {
    const b = new TokenBucket({ capacity: 1, refillPerSecond: 2, now: () => 0 });
    b.take("x");
    try {
      b.take("x");
      expect.unreachable();
    } catch (e) {
      expect(e).toMatchObject({ code: "rate_limited", retry_safe: true, retry_after_ms: 500 });
    }
  });
});

describe("cursor codec", () => {
  it("round-trips an opaque base64url cursor", () => {
    const c = encodeCursor("list|status=sold", 41);
    expect(c).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(decodeCursor("w", c, "list|status=sold")).toBe(41);
  });

  it("fails: rejects a cursor from different filters", () => {
    const c = encodeCursor("list|status=sold", 41);
    expect(() => decodeCursor("w", c, "list|status=active")).toThrow(/different tool or different filters/);
  });

  it("fails: rejects garbage cursors", () => {
    expect(() => decodeCursor("w", "%%%", "s")).toThrow(ToolError);
    expect(() => decodeCursor("w", Buffer.from("{\"v\":2}").toString("base64url"), "s")).toThrow(/malformed/);
  });
});
