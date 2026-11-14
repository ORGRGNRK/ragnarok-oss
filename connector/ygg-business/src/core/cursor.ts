/**
 * Opaque pagination cursors. A cursor is base64url(JSON) carrying the keyset
 * position plus a scope string (tool + filters). The server keeps no paging
 * state: everything needed to resume is inside the cursor the client holds.
 */
import { ToolError } from "./errors.js";

export interface CursorPayload {
  v: 1;
  /** Scope the cursor is valid for, e.g. "list_items|status=Sold". */
  s: string;
  /** Last id returned (keyset position). */
  k: number;
}

export function encodeCursor(scope: string, lastId: number): string {
  const payload: CursorPayload = { v: 1, s: scope, k: lastId };
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

export function decodeCursor(what: string, cursor: string, scope: string): number {
  const bad = (why: string) =>
    new ToolError({
      code: "invalid_cursor",
      what,
      why,
      retry_safe: false,
      fix: "omit `cursor` to start from the first page, or pass the exact next_cursor from the previous result with the same filters",
    });
  if (!/^[A-Za-z0-9_-]+$/.test(cursor)) throw bad("the cursor is not a base64url string produced by this server");
  let p: Partial<CursorPayload>;
  try {
    p = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as Partial<CursorPayload>;
  } catch {
    throw bad("the cursor could not be decoded");
  }
  if (p?.v !== 1 || typeof p.s !== "string" || !Number.isSafeInteger(p.k)) {
    throw bad("the cursor is malformed or from an incompatible version");
  }
  if (p.s !== scope) throw bad("the cursor belongs to a different tool or different filters");
  return p.k as number;
}
