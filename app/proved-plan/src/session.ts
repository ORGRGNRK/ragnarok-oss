import type { Env } from './env';
import { randomId } from './http';

export const SESSION_COOKIE = '__Host-plan_sid';
/** Sessions last 7 days, both in the cookie and in KV. */
export const SESSION_TTL_SECONDS = 60 * 60 * 24 * 7;
const ID_FORMAT = /^[A-Za-z0-9_-]{43}$/;

export function sessionCookie(id: string): string {
  return `${SESSION_COOKIE}=${id}; Path=/; Max-Age=${SESSION_TTL_SECONDS}; HttpOnly; Secure; SameSite=Strict`;
}

export function clearedSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`;
}

/** Create a random session id in KV with a TTL; returns the Set-Cookie value. */
export async function createSession(env: Env): Promise<string> {
  const id = randomId(32);
  await env.PLAN_KV.put(`sess:${id}`, JSON.stringify({ created: Date.now() }), {
    expirationTtl: SESSION_TTL_SECONDS,
  });
  return sessionCookie(id);
}

function readSessionId(req: Request): string | null {
  const header = req.headers.get('cookie');
  if (!header) return null;
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === SESSION_COOKIE) {
      const v = part.slice(eq + 1).trim();
      return ID_FORMAT.test(v) ? v : null;
    }
  }
  return null;
}

export async function hasSession(req: Request, env: Env): Promise<boolean> {
  const id = readSessionId(req);
  if (!id) return false;
  return (await env.PLAN_KV.get(`sess:${id}`)) !== null;
}

export async function destroySession(req: Request, env: Env): Promise<void> {
  const id = readSessionId(req);
  if (id) await env.PLAN_KV.delete(`sess:${id}`);
}
