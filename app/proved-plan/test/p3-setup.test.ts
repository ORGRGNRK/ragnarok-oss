import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import { CRED_KEY } from '../src/auth';
import { call, makeEnv, registerOwner, SoftAuthenticator, TEST_SETUP_TOKEN } from './helpers';

describe('P3 single-owner setup', () => {
  it('P3: refused without the SETUP_TOKEN (missing, wrong, or no secret configured)', async () => {
    const env = makeEnv();
    for (const body of [{}, { token: '' }, { token: 'wrong-token-wrong-token-wrong' }, { token: TEST_SETUP_TOKEN + 'x' }]) {
      const res = await call(env, '/auth/register/options', { body });
      expect(res.status).toBe(403);
    }
    // verify endpoint is guarded the same way, even with a well-formed response
    const auth = new SoftAuthenticator();
    const res = await call(env, '/auth/register/verify', {
      body: { token: 'nope', flowId: 'A'.repeat(32), response: auth.register({ challenge: 'AAAA' }) },
    });
    expect(res.status).toBe(403);

    // A deployment without the secret refuses registration even with the "right" value.
    const noSecret = makeEnv({ SETUP_TOKEN: undefined });
    expect((await call(noSecret, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN } })).status).toBe(403);
    expect(env.PLAN_KV.data.has(CRED_KEY)).toBe(false);
  });

  it('P3: the correct SETUP_TOKEN registers the first passkey', async () => {
    const env = makeEnv();
    const { cookie } = await registerOwner(env);
    expect(cookie).toMatch(/^__Host-plan_sid=/);
    expect(env.PLAN_KV.data.has(CRED_KEY)).toBe(true);
  });

  it('P3: refused once a credential exists even with the token', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);
    const before = env.PLAN_KV.data.get(CRED_KEY);

    const opt = await call(env, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN } });
    expect(opt.status).toBe(403);
    expect(await opt.text()).toMatch(/already registered/);

    // Even a full verify call with a fresh valid credential and the right token is refused.
    const intruder = new SoftAuthenticator();
    const res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: 'A'.repeat(32), response: intruder.register({ challenge: 'AAAA' }) },
    });
    expect(res.status).toBe(403);
    expect(env.PLAN_KV.data.get(CRED_KEY)).toBe(before);
    expect(JSON.parse(before!).id).toBe(auth.id);

    // The login page no longer offers setup.
    const page = await (await call(env, '/')).text();
    expect(page).not.toContain('id="register"');
  });

  it('P3: a registration started before the owner registered cannot complete afterwards', async () => {
    const env = makeEnv();
    const a = await call(env, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN } });
    const pending = (await a.json()) as { flowId: string; options: { challenge: string } };
    await registerOwner(env);
    const late = new SoftAuthenticator();
    const res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: pending.flowId, response: late.register(pending.options) },
    });
    expect(res.status).toBe(403);
  });
});
