import { ToolError } from "./errors.js";

export interface RateLimitOptions {
  /** Maximum burst size. */
  capacity: number;
  /** Tokens added per second. */
  refillPerSecond: number;
  /** Injectable clock (ms) for tests. */
  now?: () => number;
}

/**
 * Token bucket. One instance per server, passed in explicitly (never a module
 * singleton), so tests can give each server its own limiter.
 */
export class TokenBucket {
  private tokens: number;
  private last: number;
  private readonly now: () => number;

  constructor(private readonly opts: RateLimitOptions) {
    if (opts.capacity < 1 || opts.refillPerSecond <= 0) throw new Error("invalid rate limit options");
    this.now = opts.now ?? Date.now;
    this.tokens = opts.capacity;
    this.last = this.now();
  }

  private refill(): void {
    const t = this.now();
    const elapsed = Math.max(0, t - this.last) / 1000;
    this.tokens = Math.min(this.opts.capacity, this.tokens + elapsed * this.opts.refillPerSecond);
    this.last = t;
  }

  /** Take one token or throw a rate_limited ToolError. */
  take(what: string): void {
    this.refill();
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return;
    }
    const wait = Math.ceil(((1 - this.tokens) / this.opts.refillPerSecond) * 1000);
    throw new ToolError({
      code: "rate_limited",
      what,
      why: `this server allows ${this.opts.capacity} calls in a burst and ${this.opts.refillPerSecond} per second sustained`,
      retry_safe: true,
      retry_after_ms: wait,
      fix: `wait about ${wait} ms and retry; batch work with larger page sizes instead of many small calls`,
    });
  }
}
