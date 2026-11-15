import { vi } from 'vitest';

// Vitest has no .md loader (and the suite runs without a config file so nothing is
// written into the project), so src/plan-text.ts gets the very same plan-content.md text.
vi.mock('../src/plan-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8') };
});
import { describe, expect, it } from 'vitest';
import { CRED_KEY } from '../src/auth';
import { call, login, loginOptions, makeEnv, registerOwner, SoftAuthenticator, TEST_SETUP_TOKEN } from './helpers';

async function regOptions(env: ReturnType<typeof makeEnv>) {
  const res = await call(env, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN } });
  expect(res.status).toBe(200);
  return (await res.json()) as {
    flowId: string;
    options: { challenge: string; authenticatorSelection: Record<string, unknown>; rp: { id: string } };
  };
}

describe('P4 WebAuthn requirements', () => {
  it('P4: registration demands user verification and a platform authenticator', async () => {
    const env = makeEnv();
    const { options } = await regOptions(env);
    expect(options.rp.id).toBe('plan.rgnrk.co');
    expect(options.authenticatorSelection.userVerification).toBe('required');
    expect(options.authenticatorSelection.authenticatorAttachment).toBe('platform');
    expect(options.authenticatorSelection.residentKey).toBe('required');

    // No user verification flag (UV) -> refused
    let r = await regOptions(env);
    let res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: r.flowId, response: new SoftAuthenticator().register(r.options, { uv: false }) },
    });
    expect(res.status).toBe(400);

    // Roaming / security key -> refused
    r = await regOptions(env);
    res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: r.flowId, response: new SoftAuthenticator().register(r.options, { attachment: 'cross-platform' }) },
    });
    expect(res.status).toBe(400);

    // Attachment not reported -> refused
    r = await regOptions(env);
    res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: r.flowId, response: new SoftAuthenticator().register(r.options, { attachment: undefined }) },
    });
    expect(res.status).toBe(400);

    // Wrong origin (phishing site) -> refused
    r = await regOptions(env);
    res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: r.flowId, response: new SoftAuthenticator().register(r.options, { origin: 'https://evil.example' }) },
    });
    expect(res.status).toBe(400);
    expect(env.PLAN_KV.data.has(CRED_KEY)).toBe(false);

    // Platform + UV -> accepted
    r = await regOptions(env);
    res = await call(env, '/auth/register/verify', {
      body: { token: TEST_SETUP_TOKEN, flowId: r.flowId, response: new SoftAuthenticator().register(r.options) },
    });
    expect(res.status).toBe(200);
  });

  it('P4: login demands user verification and a platform authenticator', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);

    const { options } = await loginOptions(env);
    expect(options.userVerification).toBe('required');
    expect(options.rpId).toBe('plan.rgnrk.co');
    expect((options.allowCredentials as { id: string }[]).map((c) => c.id)).toEqual([auth.id]);

    let o = await loginOptions(env);
    let res = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: auth.assert(o.options, { uv: false }) } });
    expect(res.status).toBe(401);
    expect(res.headers.get('set-cookie')).toBeNull();

    o = await loginOptions(env);
    res = await call(env, '/auth/login/verify', {
      body: { flowId: o.flowId, response: auth.assert(o.options, { attachment: 'cross-platform' }) },
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('set-cookie')).toBeNull();

    // With UV on the platform authenticator it works.
    const cookie = await login(env, auth);
    expect((await call(env, '/api/state?day=2026-11-07', { cookie })).status).toBe(200);
  });

  it('P4: a bad assertion is refused', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);

    // Signature from a different key (same credential id)
    const impostor = new SoftAuthenticator();
    Object.defineProperty(impostor, 'credId', { value: auth.credId });
    let o = await loginOptions(env);
    let res = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: impostor.assert(o.options) } });
    expect(res.status).toBe(401);

    // Tampered signature bytes
    o = await loginOptions(env);
    const good = auth.assert(o.options);
    const sig = Buffer.from(good.response.signature, 'base64url');
    sig[sig.length - 1] ^= 0xff;
    res = await call(env, '/auth/login/verify', {
      body: { flowId: o.flowId, response: { ...good, response: { ...good.response, signature: sig.toString('base64url') } } },
    });
    expect(res.status).toBe(401);

    // Signed over a different challenge
    o = await loginOptions(env);
    res = await call(env, '/auth/login/verify', {
      body: { flowId: o.flowId, response: auth.assert({ challenge: 'ZmFrZS1jaGFsbGVuZ2U' }) },
    });
    expect(res.status).toBe(401);

    // Wrong origin
    o = await loginOptions(env);
    res = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: auth.assert(o.options, { origin: 'https://evil.example' }) } });
    expect(res.status).toBe(401);

    // Unknown credential id
    o = await loginOptions(env);
    res = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: new SoftAuthenticator().assert(o.options) } });
    expect(res.status).toBe(401);

    // Garbage
    o = await loginOptions(env);
    res = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: { id: auth.id, response: {} } } });
    expect(res.status).toBe(401);

    const sessions = [...env.PLAN_KV.data.keys()].filter((k) => k.startsWith('sess:'));
    expect(sessions).toHaveLength(1); // only the one from registration
  });

  it('P4: a replayed assertion is refused', async () => {
    const env = makeEnv();
    const { auth } = await registerOwner(env);
    const o = await loginOptions(env);
    const assertion = auth.assert(o.options);

    const first = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: assertion } });
    expect(first.status).toBe(200);

    // Same assertion, same flow: the challenge was single-use.
    const replay = await call(env, '/auth/login/verify', { body: { flowId: o.flowId, response: assertion } });
    expect(replay.status).toBe(401);
    expect(replay.headers.get('set-cookie')).toBeNull();

    // Same assertion against a fresh challenge: challenge mismatch.
    const o2 = await loginOptions(env);
    const replay2 = await call(env, '/auth/login/verify', { body: { flowId: o2.flowId, response: assertion } });
    expect(replay2.status).toBe(401);
    expect(replay2.headers.get('set-cookie')).toBeNull();
  });

  it('P4: WebAuthn POSTs from another origin are refused', async () => {
    const env = makeEnv();
    const res = await call(env, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN }, origin: 'https://evil.example' });
    expect(res.status).toBe(403);
  });
});
