import { vi } from 'vitest';

vi.mock('../src/copy-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../copy.md', import.meta.url), 'utf8') };
});

import { describe, expect, it } from 'vitest';
import { RATE_LIMIT } from '../src/intake';
import { call, intakeKeys, makeEnv, validForm } from './helpers';

describe('intake', () => {
  it('shows the onboarding steps and a form that works without JavaScript', async () => {
    const body = await (await call(makeEnv(), '/welcome')).text();
    expect(body).toContain('Agree the job');
    expect(body).toContain('<form method="post" action="/intake"');
    expect(body).toContain('name="company_website"');
    expect(body).not.toContain('<script');
  });

  it('stores a valid ticket under intake:<ts>:<ticket> and shows the ticket number', async () => {
    const env = makeEnv();
    const res = await call(env, '/intake', { form: validForm });
    expect(res.status).toBe(200);
    const keys = await intakeKeys(env);
    expect(keys).toHaveLength(1);
    expect(keys[0]).toMatch(/^intake:\d+:[2-9A-HJ-NP-Z]{6}$/);
    const stored = JSON.parse((await env.SITE_KV.get(keys[0]!)) ?? '{}') as { name: string; email: string; ticket: string };
    expect(stored.name).toBe('Ada Lovelace');
    expect(stored.email).toBe('ada@example.com');
    expect(keys[0]!.endsWith(':' + stored.ticket)).toBe(true);
    const body = await res.text();
    expect(body).toContain('Ada Lovelace');
    expect(body).toContain(`Ticket <strong>#${stored.ticket}</strong>`);
    expect(body).toContain('Queued');
  });

  it('rejects a missing email and does not store it', async () => {
    const env = makeEnv();
    const res = await call(env, '/intake', { form: { ...validForm, email: '' } });
    expect(res.status).toBe(400);
    expect(await res.text()).toContain('Email is required.');
    expect(await intakeKeys(env)).toHaveLength(0);
  });

  it('HTML-escapes the name on the way back out', async () => {
    const env = makeEnv();
    const res = await call(env, '/intake', { form: { ...validForm, name: 'A <b>Name</b>' } });
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain('&lt;b&gt;');
    expect(body).not.toContain('<b>');
    const bad = await call(env, '/intake', {
      ip: '203.0.113.50',
      form: { ...validForm, name: '<script>alert(1)</script>', email: 'not-an-email' },
    });
    expect(bad.status).toBe(400);
    const errors = await bad.text();
    expect(errors).toContain('&lt;script&gt;');
    expect(errors).not.toContain('<script>');
  });

  it('drops a honeypot fill without storing it', async () => {
    const env = makeEnv();
    const res = await call(env, '/intake', { form: { ...validForm, company_website: 'http://spam.example' } });
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('Thanks');
    expect(await intakeKeys(env)).toHaveLength(0);
  });

  it('rate limits by IP', async () => {
    const env = makeEnv();
    for (let i = 0; i < RATE_LIMIT; i++) {
      const res = await call(env, '/intake', { form: { ...validForm, email: `p${i}@example.com` } });
      expect(res.status).toBe(200);
    }
    const blocked = await call(env, '/intake', { form: { ...validForm, email: 'over@example.com' } });
    expect(blocked.status).toBe(429);
    expect(await intakeKeys(env)).toHaveLength(RATE_LIMIT);
    const other = await call(env, '/intake', {
      ip: '203.0.113.99',
      form: { ...validForm, email: 'other@example.com' },
    });
    expect(other.status).toBe(200);
    expect(await intakeKeys(env)).toHaveLength(RATE_LIMIT + 1);
  });

  it('refuses a form posted from another site', async () => {
    const env = makeEnv();
    const res = await call(env, '/intake', { form: validForm, origin: 'https://evil.example' });
    expect(res.status).toBe(403);
    expect(await intakeKeys(env)).toHaveLength(0);
  });
});
