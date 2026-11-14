/**
 * Secret redaction. Applied to every error text, log line and receipt argument
 * before it leaves the process or reaches storage.
 */

const MASK = "***";

/** Keys whose values are always masked, wherever they appear in an object. */
const SECRET_KEY = /(pass(word)?|pwd|secret|token|api[_-]?key|authorization|cookie|credential)/i;

/** scheme://user:password@host -> scheme://user:***@host */
const URL_CREDENTIALS = /\b([a-z][a-z0-9+.-]*:\/\/[^\s:/@]+):([^\s@/]+)@/gi;

/** key=value / key: value pairs in free text, e.g. "password=hunter2". */
const INLINE_SECRET = /\b(pass(?:word)?|pwd|secret|token|api[_-]?key)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;&]+)/gi;

export interface Redactor {
  text(input: string): string;
  value<T>(input: T): T;
}

/**
 * Build a redactor. `secrets` are literal values (e.g. passwords parsed out of
 * the configured database URLs) that are masked anywhere they appear.
 */
export function createRedactor(secrets: Array<string | undefined> = []): Redactor {
  const literals = secrets
    .filter((s): s is string => typeof s === "string" && s.length >= 4)
    .flatMap((s) => {
      const enc = encodeURIComponent(s);
      return enc === s ? [s] : [s, enc];
    })
    .sort((a, b) => b.length - a.length);

  const text = (input: string): string => {
    let out = input.replace(URL_CREDENTIALS, `$1:${MASK}@`).replace(INLINE_SECRET, `$1$2${MASK}`);
    for (const lit of literals) out = out.split(lit).join(MASK);
    return out;
  };

  const value = <T>(input: T): T => walk(input, text, 0) as T;

  return { text, value };
}

function walk(v: unknown, text: (s: string) => string, depth: number): unknown {
  if (depth > 20) return MASK;
  if (typeof v === "string") return text(v);
  if (Array.isArray(v)) return v.map((x) => walk(x, text, depth + 1));
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = SECRET_KEY.test(k) ? MASK : walk(val, text, depth + 1);
    }
    return out;
  }
  return v;
}

/** Extract the password from a postgres URL so it can be added to a redactor. */
export function passwordFromUrl(url: string | undefined): string | undefined {
  if (!url) return undefined;
  try {
    const p = new URL(url).password;
    return p ? decodeURIComponent(p) : undefined;
  } catch {
    return undefined;
  }
}
