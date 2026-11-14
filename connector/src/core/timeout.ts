import { ToolError } from "./errors.js";

/**
 * Race a promise against a deadline. On expiry the caller gets a timeout
 * ToolError; the AbortSignal lets well-behaved work (fetch) stop early.
 */
export async function withTimeout<T>(
  what: string,
  ms: number,
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const ctl = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ctl.abort();
      reject(
        new ToolError({
          code: "timeout",
          what,
          why: `the operation did not finish within ${ms} ms`,
          retry_safe: true,
          fix: "retry; if it keeps timing out, narrow the request (smaller limit, add a filter)",
        }),
      );
    }, ms);
  });
  try {
    return await Promise.race([work(ctl.signal), deadline]);
  } finally {
    clearTimeout(timer);
  }
}
