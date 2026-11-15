import worker, { type Env } from '../src/index';
import type { KV, KVList } from '../src/env';

export const ORIGIN = 'http://127.0.0.1:8787';

export class MemoryKV implements KV {
  data = new Map<string, string>();
  ttls = new Map<string, number | undefined>();
  async get(key: string): Promise<string | null> {
    return this.data.get(key) ?? null;
  }
  async put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void> {
    this.data.set(key, value);
    this.ttls.set(key, options?.expirationTtl);
  }
  async delete(key: string): Promise<void> {
    this.data.delete(key);
    this.ttls.delete(key);
  }
  async list(options?: { prefix?: string; cursor?: string }): Promise<KVList> {
    const prefix = options?.prefix ?? '';
    const keys = [...this.data.keys()]
      .filter((name) => name.startsWith(prefix))
      .sort()
      .map((name) => ({ name }));
    return { keys, list_complete: true };
  }
}

export function makeEnv(
  overrides: Partial<Omit<Env, 'SITE_KV'>> = {},
): Env & { SITE_KV: MemoryKV } {
  return { SITE_KV: new MemoryKV(), ...overrides };
}

export interface CallOpts {
  method?: string;
  form?: Record<string, string>;
  origin?: string | null;
  ip?: string;
  auth?: string;
}

export async function call(env: Env, path: string, opts: CallOpts = {}): Promise<Response> {
  const method = opts.method ?? (opts.form ? 'POST' : 'GET');
  const headers: Record<string, string> = {};
  let body: string | undefined;
  if (opts.form) {
    headers['content-type'] = 'application/x-www-form-urlencoded';
    body = new URLSearchParams(opts.form).toString();
  }
  if (opts.ip) headers['cf-connecting-ip'] = opts.ip;
  else if (method === 'POST') headers['cf-connecting-ip'] = '203.0.113.10';
  if (opts.auth) headers['authorization'] = opts.auth;
  const origin = opts.origin === undefined ? (method === 'POST' ? ORIGIN : null) : opts.origin;
  if (origin) headers['origin'] = origin;
  return worker.fetch(new Request(`${ORIGIN}${path}`, { method, headers, body }), env);
}

export const validForm: Record<string, string> = {
  name: 'Ada Lovelace',
  email: 'ada@example.com',
  trying: 'The till app showed error E_TILL when I opened it.',
  last_worked: 'Yesterday, before an update.',
  machine: 'Windows 10 laptop, about four years old.',
  fixed: 'The till app opens and a test sale prints.',
  dont_touch: 'The payroll folder.',
  backup: 'yes',
  access: 'remote',
  access_tool: 'RustDesk',
  company_website: '',
};

export async function intakeKeys(env: { SITE_KV: MemoryKV }): Promise<string[]> {
  const listed = await env.SITE_KV.list({ prefix: 'intake:' });
  return listed.keys.map((key) => key.name);
}
