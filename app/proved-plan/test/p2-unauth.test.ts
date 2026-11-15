import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import { call, htmlText, makeEnv, planFromFile, registerOwner } from './helpers';

const { tasks, rhythm } = planFromFile();

describe('P2 unauthenticated access', () => {
  it('plan-content.md really has 28 tasks and 4 rhythm items (sanity)', () => {
    expect(tasks).toHaveLength(28);
    expect(rhythm).toHaveLength(4);
  });

  it('P2: unauthenticated GET / shows the login page and no plan task', async () => {
    for (const registered of [false, true]) {
      const env = makeEnv();
      if (registered) await registerOwner(env);
      const res = await call(env, '/');
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toMatch(/text\/html/);
      const body = await res.text();
      expect(body).toMatch(/Sign in with your passkey/);
      for (const t of tasks) {
        expect(body).not.toContain(htmlText(t.text));
        expect(body).not.toContain(t.text);
        expect(body).not.toContain(`data-task="${t.id}"`);
      }
      for (const r of rhythm) expect(body).not.toContain(`data-rhythm="${r.id}"`);
      expect(body).not.toMatch(/Week 1|pull it out|Show HN|Daily rhythm/);
    }
  });

  it('P2: /api/state answers 401 without a session (and with a forged one)', async () => {
    const env = makeEnv();
    await registerOwner(env);
    const res = await call(env, '/api/state?day=2026-11-07');
    expect(res.status).toBe(401);
    const forged = await call(env, '/api/state?day=2026-11-07', {
      cookie: '__Host-plan_sid=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });
    expect(forged.status).toBe(401);
    const body = await forged.text();
    for (const t of tasks) expect(body).not.toContain(t.text);
  });

  it('P2: every non-login, non-WebAuthn route needs a session', async () => {
    const env = makeEnv();
    for (const [path, body] of [
      ['/api/task', { id: 'd1', done: true }],
      ['/api/rhythm', { day: '2026-11-07', id: 'post', done: true }],
      ['/api/numbers', { day: '2026-11-07', numbers: { posts: 1 } }],
      ['/auth/logout', {}],
    ] as const) {
      expect((await call(env, path, { body })).status).toBe(401);
    }
    expect((await call(env, '/anything-else')).status).toBe(401);
    expect(env.PLAN_KV.data.has('state:tasks')).toBe(false);
  });
});
