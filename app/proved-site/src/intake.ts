import type { Env, KV } from './env';
import { clientIp } from './http';

export const RATE_LIMIT = 5;
export const RATE_WINDOW_MS = 60 * 60 * 1000;

export interface Intake {
  name: string;
  email: string;
  trying: string;
  last_worked: string;
  machine: string;
  fixed: string;
  dont_touch: string;
  backup: string;
  access: string;
  access_tool: string;
}

export const EMPTY_INTAKE: Intake = {
  name: '',
  email: '',
  trying: '',
  last_worked: '',
  machine: '',
  fixed: '',
  dont_touch: '',
  backup: '',
  access: '',
  access_tool: '',
};

const LIMITS: Record<keyof Intake, number> = {
  name: 200,
  email: 200,
  trying: 4000,
  last_worked: 2000,
  machine: 500,
  fixed: 1000,
  dont_touch: 2000,
  backup: 20,
  access: 20,
  access_tool: 500,
};

const BACKUP = new Set(['yes', 'no', 'not-sure']);
const ACCESS = new Set(['in-person', 'remote', 'not-sure']);

export type IntakeResult =
  | { status: 200; kind: 'thanks'; name: string; ticket: string }
  | { status: 200; kind: 'honeypot'; ticket: string }
  | { status: 400; kind: 'invalid'; errors: string[]; values: Intake }
  | { status: 400; kind: 'message'; message: string }
  | { status: 403; kind: 'message'; message: string }
  | { status: 413; kind: 'message'; message: string }
  | { status: 429; kind: 'message'; message: string };

function field(form: FormData, key: string): string {
  const value = form.get(key);
  return typeof value === 'string' ? value : '';
}

export function readIntake(form: FormData): Intake {
  return {
    name: field(form, 'name'),
    email: field(form, 'email'),
    trying: field(form, 'trying'),
    last_worked: field(form, 'last_worked'),
    machine: field(form, 'machine'),
    fixed: field(form, 'fixed'),
    dont_touch: field(form, 'dont_touch'),
    backup: field(form, 'backup'),
    access: field(form, 'access'),
    access_tool: field(form, 'access_tool'),
  };
}

function controlChars(value: string, multiline: boolean): boolean {
  return multiline
    ? /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(value)
    : /[\u0000-\u001F]/.test(value);
}

export function validateIntake(input: Intake): string[] {
  const errors: string[] = [];
  const check = (key: keyof Intake, label: string, required: boolean, multiline = false) => {
    const value = input[key].trim();
    if (!value) {
      if (required) errors.push(`${label} is required.`);
      return;
    }
    if (value.length > LIMITS[key]) errors.push(`${label} is too long.`);
    if (controlChars(value, multiline)) errors.push(`${label} has a character I can't store.`);
  };
  check('name', 'Name', true);
  check('email', 'Email', true);
  if (input.email.trim() && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.email.trim())) {
    errors.push('Email must look like name@example.com.');
  }
  check('trying', 'What you were trying to do', true, true);
  check('last_worked', 'When it last worked', true, true);
  check('machine', 'Machine and system', true);
  check('fixed', 'What fixed looks like', true, true);
  check('dont_touch', 'Anything not to touch', false, true);
  check('backup', 'Backup', true);
  if (input.backup.trim() && !BACKUP.has(input.backup.trim())) {
    errors.push('Backup must be yes, no, or not sure.');
  }
  check('access', 'Access', true);
  if (input.access.trim() && !ACCESS.has(input.access.trim())) {
    errors.push('Access must be in person, remote, or not sure.');
  }
  check('access_tool', 'Remote tool', false);
  return errors;
}

/**
 * Five stored or honeypot posts per IP per hour, counted from the first post
 * in the window. Validation failures count too, so a loop can't skip the limit.
 */
export async function allowIntake(kv: KV, ip: string, now = Date.now()): Promise<boolean> {
  const key = `rl:${ip}`;
  const raw = await kv.get(key);
  let count = 0;
  let resetAt = now + RATE_WINDOW_MS;
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as { count?: unknown; resetAt?: unknown };
      if (typeof parsed.resetAt === 'number' && parsed.resetAt > now && typeof parsed.count === 'number') {
        count = parsed.count;
        resetAt = parsed.resetAt;
      }
    } catch {
      count = 0;
    }
  }
  if (count >= RATE_LIMIT) return false;
  const ttl = Math.max(60, Math.ceil((resetAt - now) / 1000));
  await kv.put(key, JSON.stringify({ count: count + 1, resetAt }), { expirationTtl: ttl });
  return true;
}

/** A short ticket number the customer can quote back: 6 characters, no look-alikes (no 0/O, 1/I). */
export function newTicket(): string {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
}

export async function storeIntake(kv: KV, input: Intake, now = Date.now(), ticket = newTicket()): Promise<string> {
  const key = `intake:${now}:${ticket}`;
  const stored: Record<string, string> = { at: new Date(now).toISOString(), ticket };
  for (const fieldName of Object.keys(EMPTY_INTAKE) as (keyof Intake)[]) {
    stored[fieldName] = input[fieldName].trim();
  }
  await kv.put(key, JSON.stringify(stored));
  return key;
}

export async function takeIntake(req: Request, env: Env): Promise<IntakeResult> {
  const origin = req.headers.get('origin');
  if (origin && origin !== new URL(req.url).origin) {
    return { status: 403, kind: 'message', message: 'That form was sent from another site.' };
  }
  const type = (req.headers.get('content-type') ?? '').toLowerCase();
  if (!type.startsWith('application/x-www-form-urlencoded') && !type.startsWith('multipart/form-data')) {
    return { status: 400, kind: 'message', message: 'Send the ticket form from the page.' };
  }
  const declared = Number(req.headers.get('content-length') ?? '0');
  if (Number.isFinite(declared) && declared > 100_000) {
    return { status: 413, kind: 'message', message: 'That form is too large.' };
  }
  let form: FormData;
  try {
    if (type.startsWith('application/x-www-form-urlencoded')) {
      const textBody = await req.text();
      if (textBody.length > 100_000) {
        return { status: 413, kind: 'message', message: 'That form is too large.' };
      }
      form = new FormData();
      for (const [key, value] of new URLSearchParams(textBody)) form.append(key, value);
    } else {
      form = await req.formData();
    }
  } catch {
    return { status: 400, kind: 'message', message: 'The form could not be read.' };
  }
  const rawBody = [...form.values()].reduce((n, v) => n + (typeof v === 'string' ? v.length : 0), 0);
  if (rawBody > 100_000) {
    return { status: 413, kind: 'message', message: 'That form is too large.' };
  }

  const ip = clientIp(req);
  if (!(await allowIntake(env.SITE_KV, ip))) {
    return {
      status: 429,
      kind: 'message',
      message: 'Too many forms from this network in the last hour. Wait and try again.',
    };
  }

  // Honeypot: same thank-you as a real post, and nothing is stored.
  if (field(form, 'company_website').trim()) {
    return { status: 200, kind: 'honeypot', ticket: newTicket() };
  }

  const values = readIntake(form);
  const errors = validateIntake(values);
  if (errors.length) return { status: 400, kind: 'invalid', errors, values };

  const ticket = newTicket();
  await storeIntake(env.SITE_KV, values, Date.now(), ticket);
  return { status: 200, kind: 'thanks', name: values.name.trim(), ticket };
}
