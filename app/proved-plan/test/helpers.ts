import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { isoCBOR } from '@simplewebauthn/server/helpers';
import worker, { type Env } from '../src/index';
import type { KV } from '../src/env';

export const RP_ID = 'plan.rgnrk.co';
export const ORIGIN = 'https://plan.rgnrk.co';
// Test-only value, never used anywhere real.
export const TEST_SETUP_TOKEN = 'test-only-setup-token-0123456789';

/** In-memory KV that records the TTL of each put. */
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
}

export function makeEnv(overrides: Partial<Env> = {}): Env & { PLAN_KV: MemoryKV } {
  return {
    PLAN_KV: new MemoryKV(),
    SETUP_TOKEN: TEST_SETUP_TOKEN,
    RP_ID,
    ORIGIN,
    RP_NAME: 'Proved plan',
    ...overrides,
  } as Env & { PLAN_KV: MemoryKV };
}

export interface CallOpts {
  method?: string;
  body?: unknown;
  cookie?: string;
  origin?: string | null;
  bearer?: string;
}

export async function call(env: Env, path: string, opts: CallOpts = {}): Promise<Response> {
  const method = opts.method ?? (opts.body !== undefined ? 'POST' : 'GET');
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers['content-type'] = 'application/json';
  if (opts.cookie) headers['cookie'] = opts.cookie;
  if (opts.bearer !== undefined) headers['authorization'] = `Bearer ${opts.bearer}`;
  const origin = opts.origin === undefined ? ORIGIN : opts.origin;
  if (origin && method !== 'GET') headers['origin'] = origin;
  const req = new Request(`${ORIGIN}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  return worker.fetch(req, env);
}

/** "name=value" from a Set-Cookie header, ready to send back. */
export function cookieFrom(res: Response): string {
  const sc = res.headers.get('set-cookie');
  if (!sc) throw new Error('no set-cookie');
  return sc.split(';')[0]!;
}

const b64u = (b: Uint8Array | Buffer) => Buffer.from(b).toString('base64url');

const FLAG_UP = 0x01;
const FLAG_UV = 0x04;
const FLAG_BE = 0x08;
const FLAG_BS = 0x10;
const FLAG_AT = 0x40;

export interface AuthOpts {
  uv?: boolean;
  attachment?: 'platform' | 'cross-platform' | undefined;
  origin?: string;
}

/**
 * A software passkey (ES256) that produces real WebAuthn registration and
 * assertion responses, so the server's actual verification code is exercised.
 */
export class SoftAuthenticator {
  readonly credId = randomBytes(16);
  private readonly privateKey: KeyObject;
  private readonly x: Buffer;
  private readonly y: Buffer;
  counter = 0;

  constructor() {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    this.privateKey = privateKey;
    const jwk = publicKey.export({ format: 'jwk' });
    this.x = Buffer.from(jwk.x!, 'base64url');
    this.y = Buffer.from(jwk.y!, 'base64url');
  }

  get id(): string {
    return b64u(this.credId);
  }

  private clientData(type: string, challenge: string, origin: string): Buffer {
    return Buffer.from(JSON.stringify({ type, challenge, origin, crossOrigin: false }));
  }

  private flags(uv: boolean, extra = 0): number {
    return FLAG_UP | (uv ? FLAG_UV : 0) | FLAG_BE | FLAG_BS | extra;
  }

  private counterBytes(): Buffer {
    const b = Buffer.alloc(4);
    b.writeUInt32BE(this.counter);
    return b;
  }

  register(options: { challenge: string }, opts: AuthOpts = {}) {
    const uv = opts.uv ?? true;
    const attachment = 'attachment' in opts ? opts.attachment : 'platform';
    const rpIdHash = createHash('sha256').update(RP_ID).digest();
    const cose = new Map<number, number | Uint8Array>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, new Uint8Array(this.x)],
      [-3, new Uint8Array(this.y)],
    ]);
    const coseBytes = Buffer.from(isoCBOR.encode(cose));
    const credLen = Buffer.alloc(2);
    credLen.writeUInt16BE(this.credId.length);
    const authData = Buffer.concat([
      rpIdHash,
      Buffer.from([this.flags(uv, FLAG_AT)]),
      this.counterBytes(),
      Buffer.alloc(16), // aaguid
      credLen,
      this.credId,
      coseBytes,
    ]);
    const attestationObject = Buffer.from(
      isoCBOR.encode(new Map<string, unknown>([['fmt', 'none'], ['attStmt', new Map()], ['authData', new Uint8Array(authData)]]) as never),
    );
    return {
      id: this.id,
      rawId: this.id,
      type: 'public-key' as const,
      authenticatorAttachment: attachment,
      clientExtensionResults: {},
      response: {
        clientDataJSON: b64u(this.clientData('webauthn.create', options.challenge, opts.origin ?? ORIGIN)),
        attestationObject: b64u(attestationObject),
        transports: ['internal', 'hybrid'],
      },
    };
  }

  assert(options: { challenge: string }, opts: AuthOpts = {}) {
    const uv = opts.uv ?? true;
    const attachment = 'attachment' in opts ? opts.attachment : 'platform';
    const rpIdHash = createHash('sha256').update(RP_ID).digest();
    const authData = Buffer.concat([rpIdHash, Buffer.from([this.flags(uv)]), this.counterBytes()]);
    const clientDataJSON = this.clientData('webauthn.get', options.challenge, opts.origin ?? ORIGIN);
    const signature = sign('sha256', Buffer.concat([authData, createHash('sha256').update(clientDataJSON).digest()]), this.privateKey);
    return {
      id: this.id,
      rawId: this.id,
      type: 'public-key' as const,
      authenticatorAttachment: attachment,
      clientExtensionResults: {},
      response: {
        clientDataJSON: b64u(clientDataJSON),
        authenticatorData: b64u(authData),
        signature: b64u(signature),
        userHandle: undefined,
      },
    };
  }
}

/** Register the owner passkey through the real endpoints; returns the authenticator and session cookie. */
export async function registerOwner(env: Env, auth = new SoftAuthenticator()) {
  const optRes = await call(env, '/auth/register/options', { body: { token: TEST_SETUP_TOKEN } });
  if (optRes.status !== 200) throw new Error(`register options ${optRes.status}`);
  const { flowId, options } = (await optRes.json()) as { flowId: string; options: { challenge: string } };
  const res = await call(env, '/auth/register/verify', {
    body: { token: TEST_SETUP_TOKEN, flowId, response: auth.register(options) },
  });
  if (res.status !== 200) throw new Error(`register verify ${res.status}: ${await res.text()}`);
  return { auth, cookie: cookieFrom(res) };
}

export async function loginOptions(env: Env) {
  const res = await call(env, '/auth/login/options', { body: {} });
  return (await res.json()) as { flowId: string; options: Record<string, unknown> & { challenge: string } };
}

export async function login(env: Env, auth: SoftAuthenticator): Promise<string> {
  const { flowId, options } = await loginOptions(env);
  const res = await call(env, '/auth/login/verify', { body: { flowId, response: auth.assert(options) } });
  if (res.status !== 200) throw new Error(`login ${res.status}: ${await res.text()}`);
  return cookieFrom(res);
}

/** The 28 day tasks and 4 rhythm items read straight from plan-content.md (independent of src/plan.ts). */
export function planFromFile() {
  const md = readFileSync(new URL('../plan-content.md', import.meta.url), 'utf8');
  const tasks: { id: string; text: string }[] = [];
  const rhythm: { id: string; label: string }[] = [];
  let inRhythm = false;
  for (const line of md.split('\n')) {
    if (line.startsWith('## ')) inRhythm = /Daily rhythm/.test(line);
    const t = /^- (d\d+): (.+)$/.exec(line);
    if (t) tasks.push({ id: t[1]!, text: t[2]!.trim() });
    const r = /^- ([a-z]+): ([^—]+?) —/.exec(line);
    if (inRhythm && r) rhythm.push({ id: r[1]!, label: r[2]!.trim() });
  }
  return { tasks, rhythm };
}

export function htmlText(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
