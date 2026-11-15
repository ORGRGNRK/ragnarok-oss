import { vi } from 'vitest';

vi.mock('../src/copy-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../copy.md', import.meta.url), 'utf8') };
});

import { describe, expect, it } from 'vitest';
import { call, makeEnv } from './helpers';

// Payment happens after the free diagnosis, by agreement. The public page has no Pay button.
describe('pay buttons', () => {
  it('shows no Pay button and no disabled placeholder button', async () => {
    const body = await (await call(makeEnv(), '/')).text();
    expect(body).not.toContain('>Pay</a>');
    expect(body).not.toContain('Payment link not set yet');
  });

  it('a set PAY_URL never adds a button for a price that is not a placeholder tier', async () => {
    const body = await (await call(makeEnv({ PAY_URL_INTRO: 'https://buy.stripe.com/test_intro' }), '/')).text();
    expect(body).not.toContain('buy.stripe.com');
  });
});
