import { vi } from 'vitest';

vi.mock('../src/copy-text', async () => {
  const { readFileSync } = await import('node:fs');
  return { default: readFileSync(new URL('../copy.md', import.meta.url), 'utf8') };
});

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SECTION_TITLES, parseCopy, parsePricing } from '../src/copy';
import { call, makeEnv } from './helpers';

const md = readFileSync(new URL('../copy.md', import.meta.url), 'utf8');

describe('copy', () => {
  it('parseCopy keeps the eight sections in order', () => {
    const copy = parseCopy(md);
    expect(copy.title).toBe('Proved');
    expect(copy.sections.map((s) => s.title)).toEqual([...SECTION_TITLES]);
  });

  it('parseCopy rejects a page that drops a section', () => {
    expect(() => parseCopy('# Proved\n\n## Hero\n\nHi\n')).toThrow(/sections/);
  });

  it('pricing states a free diagnosis and a $50 one-time fix and bigger fixes from ~$200, with no placeholder left', async () => {
    const pricing = parseCopy(md).sections.find((s) => s.title === 'Pricing');
    expect(pricing).toBeTruthy();
    expect(pricing!.body).toContain('Diagnosis: free');
    expect(pricing!.body).toContain('One-time fix: $50.');
    expect(pricing!.body).toContain('Bigger pipeline fixes: upwards of ~$200.');
    expect(md).not.toMatch(/\[(PRICE|owner decides|OTHER TIERS)/);
    const body = await (await call(makeEnv(), '/')).text();
    expect(body).toContain('One-time fix: $50.');
    expect(body).toContain('upwards of ~$200');
    expect(body).not.toContain('flat');
  });

  it('parsePricing still turns a placeholder price line into a tier', () => {
    const { tiers } = parsePricing('- Intro job — [PRICE: owner sets] — one job');
    expect(tiers.map((t) => t.id)).toEqual(['INTRO']);
  });

  it('highlights placeholders and links the whole offer', async () => {
    const res = await call(makeEnv(), '/');
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toMatch(/text\/html/);
    const body = await res.text();
    expect(body).toContain('<mark class="placeholder">[REPO_URL]</mark>');
    expect(body).toContain('prefers-color-scheme:dark');
    expect(body).toContain('href="https://plan.rgnrk.co"');
    expect(body).toContain('href="/welcome"');
    expect(body).toContain('id="offer"');
    expect(body).toContain('id="pricing"');
    expect(body).toContain('id="sample-proof-report"');
    expect(body).toContain('id="open-source"');
    expect(body).toContain('id="faq"');
    expect(body).toContain('>Send a ticket</a>');
    expect(body).not.toContain('<script');
  });

  it('replaces [REPO_URL] when the env is an https link', async () => {
    const body = await (await call(makeEnv({ REPO_URL: 'https://example.com/proved' }), '/')).text();
    expect(body).not.toContain('[REPO_URL]');
    expect(body).toContain('href="https://example.com/proved"');
  });
});
