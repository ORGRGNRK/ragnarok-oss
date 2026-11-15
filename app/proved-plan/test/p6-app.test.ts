import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import worker from '../src/index';
import { call, htmlText, login, makeEnv, planFromFile, registerOwner } from './helpers';

const { tasks, rhythm } = planFromFile();
const DAY = '2026-11-07';

describe('P6 signed-in checklist', () => {
  it('P6: signed-in page lists all 28 day tasks and 4 rhythm items from plan-content.md', async () => {
    expect(tasks).toHaveLength(28);
    expect(rhythm).toHaveLength(4);
    const env = makeEnv();
    const { cookie } = await registerOwner(env);
    const res = await call(env, '/', { cookie });
    expect(res.status).toBe(200);
    const body = await res.text();

    for (const t of tasks) {
      expect(body).toContain(`data-task="${t.id}"`);
      expect(body).toContain(htmlText(t.text));
    }
    expect(body.match(/data-task="/g)).toHaveLength(28);
    for (const r of rhythm) {
      expect(body).toContain(`data-rhythm="${r.id}"`);
      expect(body).toContain(htmlText(r.label));
    }
    expect(body.match(/data-rhythm="/g)).toHaveLength(4);
    for (const n of ['posts', 'replies', 'stars', 'outreach', 'calls', 'paid']) expect(body).toContain(`data-num="${n}"`);
    // grouped by week, in order
    const weekIdx = [1, 2, 3, 4].map((w) => body.indexOf(`Week ${w} `));
    expect(weekIdx.every((i) => i > 0)).toBe(true);
    expect([...weekIdx].sort((a, b) => a - b)).toEqual(weekIdx);
    expect(body.indexOf('data-task="d7"')).toBeLessThan(weekIdx[1]!);
    expect(body.indexOf('data-task="d8"')).toBeGreaterThan(weekIdx[1]!);
    // phone-ready
    expect(body).toContain('name="viewport"');
  });

  it('P6: checked task, rhythm and numbers survive a reload (KV round trip)', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);
    const cookie = await login(env, auth);

    expect((await call(env, '/api/task', { cookie, body: { id: 'd5', done: true } })).status).toBe(200);
    expect((await call(env, '/api/task', { cookie, body: { id: 'd12', done: true } })).status).toBe(200);
    expect((await call(env, '/api/task', { cookie, body: { id: 'd12', done: false } })).status).toBe(200);
    expect((await call(env, '/api/rhythm', { cookie, body: { day: DAY, id: 'post', done: true } })).status).toBe(200);
    const nums = { posts: 1, replies: 4, stars: 12, outreach: 2, calls: 1, paid: 0 };
    expect((await call(env, '/api/numbers', { cookie, body: { day: DAY, numbers: nums } })).status).toBe(200);

    // It is really in KV...
    expect(JSON.parse(env.PLAN_KV.data.get('state:tasks')!)).toEqual({ d5: true });
    expect(JSON.parse(env.PLAN_KV.data.get(`day:${DAY}`)!)).toEqual({ rhythm: { post: true }, numbers: nums });

    // ...and a reload (fresh requests, a new sign-in, only KV shared) brings it all back.
    const env2 = { ...env };
    const cookie2 = await login(env2, auth);
    const state = (await (await call(env2, `/api/state?day=${DAY}`, { cookie: cookie2 })).json()) as {
      tasks: Record<string, boolean>;
      rhythm: Record<string, boolean>;
      numbers: Record<string, number>;
    };
    expect(state.tasks).toEqual({ d5: true });
    expect(state.rhythm).toEqual({ post: true });
    expect(state.numbers).toEqual(nums);

    const page = await (await worker.fetch(new Request('https://plan.rgnrk.co/', { headers: { cookie: cookie2 } }), env2)).text();
    expect(page).toContain('data-task="d5" checked');
    expect(page).not.toContain('data-task="d12" checked');
  });

  it('P6: rhythm resets each day while day tasks persist', async () => {
    const env = makeEnv();
    const { cookie } = await registerOwner(env);
    await call(env, '/api/rhythm', { cookie, body: { day: DAY, id: 'product', done: true } });
    await call(env, '/api/task', { cookie, body: { id: 'd1', done: true } });
    await call(env, '/api/numbers', { cookie, body: { day: DAY, numbers: { posts: 3 } } });
    const next = (await (await call(env, '/api/state?day=2026-11-08', { cookie })).json()) as {
      tasks: Record<string, boolean>;
      rhythm: Record<string, boolean>;
      numbers: Record<string, number>;
    };
    expect(next.rhythm).toEqual({});
    expect(next.numbers).toEqual({});
    expect(next.tasks).toEqual({ d1: true });
  });

  it('P6: bad input is rejected and not stored', async () => {
    const env = makeEnv();
    const { cookie } = await registerOwner(env);
    expect((await call(env, '/api/task', { cookie, body: { id: 'd99', done: true } })).status).toBe(400);
    expect((await call(env, '/api/rhythm', { cookie, body: { day: '2026-13-01', id: 'post', done: true } })).status).toBe(400);
    expect((await call(env, '/api/numbers', { cookie, body: { day: DAY, numbers: { posts: -1 } } })).status).toBe(400);
    expect((await call(env, '/api/numbers', { cookie, body: { day: DAY, numbers: { hacks: 1 } } })).status).toBe(400);
    expect((await call(env, '/api/numbers', { cookie, body: { day: DAY, numbers: { posts: 1.5 } } })).status).toBe(400);
    expect((await call(env, '/api/state?day=yesterday', { cookie })).status).toBe(400);
    expect(env.PLAN_KV.data.has('state:tasks')).toBe(false);
    expect(env.PLAN_KV.data.has(`day:${DAY}`)).toBe(false);
  });
});
