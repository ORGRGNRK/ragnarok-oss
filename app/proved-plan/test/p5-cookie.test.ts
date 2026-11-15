import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import { SESSION_TTL_SECONDS } from '../src/session';
import { call, login, makeEnv, registerOwner } from './helpers';

function attrs(setCookie: string) {
  const [nv, ...rest] = setCookie.split(';').map((s) => s.trim());
  const map = new Map<string, string>();
  for (const a of rest) {
    const [k, v = ''] = a.split('=');
    map.set(k!.toLowerCase(), v);
  }
  return { nv: nv!, map };
}

describe('P5 session cookie', () => {
  it('P5: session cookie is HttpOnly, Secure, SameSite=Strict and expires', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);
    await login(env, auth);
    const o = await call(env, '/auth/login/options', { body: {} });
    expect(o.status).toBe(200);

    // check the cookie from both registration and login
    const res = await call(env, '/auth/login/options', { body: {} });
    const { flowId, options } = (await res.json()) as { flowId: string; options: { challenge: string } };
    const loginRes = await call(env, '/auth/login/verify', { body: { flowId, response: auth.assert(options) } });
    const sc = loginRes.headers.get('set-cookie')!;
    expect(sc).toBeTruthy();
    const { nv, map } = attrs(sc);

    expect(nv).toMatch(/^__Host-plan_sid=[A-Za-z0-9_-]{43}$/); // 256-bit random id
    expect(map.has('httponly')).toBe(true);
    expect(map.has('secure')).toBe(true);
    expect(map.get('samesite')).toBe('Strict');
    expect(map.get('path')).toBe('/');
    expect(map.has('domain')).toBe(false);
    const maxAge = Number(map.get('max-age'));
    expect(maxAge).toBeGreaterThan(0);
    expect(maxAge).toBeLessThanOrEqual(60 * 60 * 24 * 30);
    expect(maxAge).toBe(SESSION_TTL_SECONDS);

    // The session id lives in KV with the same TTL, so it expires server-side too.
    const id = nv.split('=')[1]!;
    expect(env.PLAN_KV.data.has(`sess:${id}`)).toBe(true);
    expect(env.PLAN_KV.ttls.get(`sess:${id}`)).toBe(SESSION_TTL_SECONDS);

    // Once KV has expired the key, the cookie is useless.
    expect((await call(env, '/api/state?day=2026-11-07', { cookie: nv })).status).toBe(200);
    await env.PLAN_KV.delete(`sess:${id}`);
    expect((await call(env, '/api/state?day=2026-11-07', { cookie: nv })).status).toBe(401);
  });

  it('P5: every session gets a fresh random id, and logout clears it', async () => {
    const env = makeEnv();
    const { auth, cookie: c1 } = await registerOwner(env);
    const c2 = await login(env, auth);
    expect(c1).not.toBe(c2);
    const out = await call(env, '/auth/logout', { body: {}, cookie: c2 });
    expect(out.status).toBe(200);
    const { map } = attrs(out.headers.get('set-cookie')!);
    expect(map.get('max-age')).toBe('0');
    expect(map.has('httponly') && map.has('secure') && map.get('samesite') === 'Strict').toBe(true);
    expect((await call(env, '/api/state?day=2026-11-07', { cookie: c2 })).status).toBe(401);
    expect((await call(env, '/api/state?day=2026-11-07', { cookie: c1 })).status).toBe(200);
  });

  it('P5: one-time challenges also expire (KV TTL)', async () => {
    const env = makeEnv();
    await registerOwner(env);
    const res = await call(env, '/auth/login/options', { body: {} });
    const { flowId } = (await res.json()) as { flowId: string };
    expect(env.PLAN_KV.ttls.get(`chal:auth:${flowId}`)).toBe(300);
  });
});
