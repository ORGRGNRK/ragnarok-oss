import { vi } from 'vitest';

vi.mock('../src/copy-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../copy.md', import.meta.url), 'utf8') };
});

import { describe, expect, it } from 'vitest';
import { call, makeEnv, validForm } from './helpers';

describe('admin intakes', () => {
  it('is a 404 when ADMIN_TOKEN is unset', async () => {
    const res = await call(makeEnv(), '/admin/intakes', { auth: 'Bearer anything' });
    expect(res.status).toBe(404);
    const blank = await call(makeEnv({ ADMIN_TOKEN: '   ' }), '/admin/intakes', { auth: 'Bearer secret' });
    expect(blank.status).toBe(404);
  });

  it('is a 401 when the bearer is missing or wrong', async () => {
    const env = makeEnv({ ADMIN_TOKEN: 'secret-token' });
    expect((await call(env, '/admin/intakes')).status).toBe(401);
    expect((await call(env, '/admin/intakes', { auth: 'Bearer no' })).status).toBe(401);
    expect((await call(env, '/admin/intakes', { auth: 'secret-token' })).status).toBe(401);
  });

  it('lists a stored intake for the right bearer, escaped', async () => {
    const env = makeEnv({ ADMIN_TOKEN: 'secret-token' });
    const posted = await call(env, '/intake', { form: { ...validForm, name: '<script>alert(1)</script>' } });
    expect(posted.status).toBe(200);
    const res = await call(env, '/admin/intakes', { auth: 'Bearer secret-token' });
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain('&lt;script&gt;');
    expect(body).not.toContain('<script>');
    expect(body).toContain('ada@example.com');
    expect(body).toContain('intake:');
  });
});
