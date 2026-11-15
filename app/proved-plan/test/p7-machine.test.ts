import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import { call, htmlText, makeEnv, planFromFile, registerOwner } from './helpers';

const TOKEN = 'daemon-test-token-0123456789abcdef';
const DAY = '2026-11-08';
const { tasks } = planFromFile();

function stored(env: { PLAN_KV: { data: Map<string, string> } }): boolean {
  return env.PLAN_KV.data.has('state:tasks') || env.PLAN_KV.data.has(`day:${DAY}`);
}

describe('P7 machine API', () => {
  it('P7: bearer calls answer 404 when DAEMON_TOKEN is unset or empty, and write nothing', async () => {
    for (const DAEMON_TOKEN of [undefined, '']) {
      const env = makeEnv({ DAEMON_TOKEN });
      const state = await call(env, `/api/state?day=${DAY}`, { bearer: TOKEN });
      const check = await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { day: DAY, id: 'post', done: true } });
      const numbers = await call(env, '/api/numbers', { bearer: TOKEN, origin: null, body: { day: DAY, numbers: { posts: 1 } } });
      expect(state.status).toBe(404);
      expect(check.status).toBe(404);
      expect(numbers.status).toBe(404);
      const body = await state.text();
      for (const t of tasks) expect(body).not.toContain(t.text);
      expect(stored(env)).toBe(false);
      // The passkey route is unchanged: no bearer still means 401, not a hidden 200.
      expect((await call(env, `/api/state?day=${DAY}`)).status).toBe(401);
    }
  });

  it('P7: a wrong bearer is 401, does not fall through to a valid session, and writes nothing', async () => {
    const env = makeEnv({ DAEMON_TOKEN: TOKEN });
    const { cookie } = await registerOwner(env);
    for (const bearer of ['nope', TOKEN.slice(0, 8), TOKEN + 'x']) {
      const state = await call(env, `/api/state?day=${DAY}`, { bearer, cookie });
      const check = await call(env, '/api/check', {
        bearer,
        cookie,
        origin: null,
        body: { day: DAY, id: 'post', done: true },
      });
      const numbers = await call(env, '/api/numbers', {
        bearer,
        cookie,
        origin: null,
        body: { day: DAY, numbers: { posts: 4 } },
      });
      expect(state.status).toBe(401);
      expect(check.status).toBe(401);
      expect(numbers.status).toBe(401);
    }
    expect(stored(env)).toBe(false);
    expect((await call(env, '/api/check', { origin: null, body: { day: DAY, id: 'post', done: true } })).status).toBe(401);
  });

  it('P7: the right bearer reads state and mirrors the checkbox and numbers writes', async () => {
    const env = makeEnv({ DAEMON_TOKEN: TOKEN });
    const { cookie } = await registerOwner(env);
    await call(env, '/api/task', { cookie, body: { id: 'd3', done: true } });

    const stateRes = await call(env, `/api/state?day=${DAY}`, { bearer: TOKEN });
    expect(stateRes.status).toBe(200);
    const state = (await stateRes.json()) as {
      ok: boolean;
      day: string;
      tasks: Record<string, boolean>;
      rhythm: Record<string, boolean>;
      numbers: Record<string, number>;
    };
    expect(state).toEqual({ ok: true, day: DAY, tasks: { d3: true }, rhythm: {}, numbers: {} });

    const check = await call(env, '/api/check', {
      bearer: TOKEN,
      origin: null,
      body: { day: DAY, id: 'post', done: true },
    });
    expect(check.status).toBe(200);
    expect(await check.json()).toEqual({ ok: true, rhythm: { post: true } });

    const task = await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { id: 'd4', done: true } });
    expect(task.status).toBe(200);
    expect(((await task.json()) as { tasks: Record<string, boolean> }).tasks).toEqual({ d3: true, d4: true });

    const off = await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { id: 'd4', done: false } });
    expect(off.status).toBe(200);

    const numbers = await call(env, '/api/numbers', {
      bearer: TOKEN,
      origin: 'https://evil.example',
      body: { day: DAY, numbers: { posts: 2, outreach: 0 } },
    });
    expect(numbers.status).toBe(200);
    expect(await numbers.json()).toEqual({ ok: true, numbers: { posts: 2, outreach: 0 } });

    // The passkey session sees the same KV the machine wrote.
    const again = (await (await call(env, `/api/state?day=${DAY}`, { cookie })).json()) as {
      tasks: Record<string, boolean>;
      rhythm: Record<string, boolean>;
      numbers: Record<string, number>;
    };
    expect(again.tasks).toEqual({ d3: true });
    expect(again.rhythm).toEqual({ post: true });
    expect(again.numbers).toEqual({ posts: 2, outreach: 0 });
  });

  it('P7: bad machine input is rejected and the passkey page still works', async () => {
    const env = makeEnv({ DAEMON_TOKEN: TOKEN });
    const { cookie } = await registerOwner(env);

    expect((await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { id: 'nope', done: true } })).status).toBe(400);
    expect((await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { day: 'yesterday', id: 'post', done: true } })).status).toBe(400);
    expect((await call(env, '/api/check', { bearer: TOKEN, origin: null, body: { id: 'd1', done: 'yes' } })).status).toBe(400);
    expect((await call(env, '/api/numbers', { bearer: TOKEN, origin: null, body: { day: DAY, numbers: { posts: -1 } } })).status).toBe(400);
    expect((await call(env, `/api/state?day=yesterday`, { bearer: TOKEN })).status).toBe(400);
    expect((await call(env, '/api/state', { bearer: TOKEN, method: 'POST', body: {} })).status).toBe(405);
    expect(env.PLAN_KV.data.has(`day:${DAY}`)).toBe(false);

    // A session cookie does not authorize the machine-only check route.
    expect((await call(env, '/api/check', { cookie, body: { day: DAY, id: 'post', done: true } })).status).toBe(401);

    // The bearer is not a session: the page stays on the login screen.
    const locked = await call(env, '/', { bearer: TOKEN });
    expect(locked.status).toBe(200);
    const lockedHtml = await locked.text();
    expect(lockedHtml).toMatch(/Sign in with your passkey/);
    expect(lockedHtml).not.toContain('data-task="d1"');
    expect(lockedHtml).not.toContain(htmlText(tasks[0]!.text));

    // The passkey session still loads the checklist and can use the page routes.
    const page = await call(env, '/', { cookie });
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain('data-task="d1"');
    expect(html).toContain('data-rhythm="post"');
    expect((await call(env, '/api/rhythm', { cookie, body: { day: DAY, id: 'system', done: true } })).status).toBe(200);
    expect((await call(env, '/api/rhythm', { cookie, origin: 'https://evil.example', body: { day: DAY, id: 'outreach', done: true } })).status).toBe(403);
    const rhythm = JSON.parse(env.PLAN_KV.data.get(`day:${DAY}`)!).rhythm;
    expect(rhythm).toEqual({ system: true });
  });
});
