import { listIntakes } from './admin';
import { COPY } from './content';
import type { Env } from './env';
import { html, randomHex, safeEqual, text } from './http';
import { takeIntake, type IntakeResult } from './intake';
import { adminPage, homePage, messagePage, thanksPage, welcomePage } from './pages';

export type { Env } from './env';

function view(env: Env, status: number, render: (nonce: string) => string): Response {
  const nonce = randomHex(16);
  return html(render(nonce), nonce, status);
}

function renderIntake(env: Env, result: IntakeResult): Response {
  if (result.kind === 'thanks') return view(env, 200, (nonce) => thanksPage(env, nonce, result.name, result.ticket));
  if (result.kind === 'honeypot') return view(env, 200, (nonce) => thanksPage(env, nonce, '', result.ticket));
  if (result.kind === 'invalid') {
    return view(env, 400, (nonce) => welcomePage(COPY, env, nonce, { errors: result.errors, values: result.values }));
  }
  const heading = result.status === 429 ? 'Slow down' : 'Not sent';
  return view(env, result.status, (nonce) => messagePage(env, nonce, heading, result.message));
}

async function admin(req: Request, env: Env): Promise<Response> {
  const token = env.ADMIN_TOKEN?.trim() ?? '';
  if (!token) return text('Not found', 404);
  const method = req.method.toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') return text('Method not allowed', 405);
  const header = req.headers.get('authorization') ?? '';
  const match = /^Bearer (\S+)$/.exec(header);
  const presented = match?.[1] ?? '';
  if (!presented || !(await safeEqual(presented, token))) {
    return text('Unauthorized', 401, { 'www-authenticate': 'Bearer' });
  }
  const rows = await listIntakes(env.SITE_KV);
  return view(env, 200, (nonce) => adminPage(env, nonce, rows));
}

async function handle(req: Request, env: Env): Promise<Response> {
  const path = new URL(req.url).pathname;
  const method = req.method.toUpperCase();

  if (path === '/admin/intakes') return admin(req, env);
  if (path === '/' && (method === 'GET' || method === 'HEAD')) {
    return view(env, 200, (nonce) => homePage(COPY, env, nonce));
  }
  if (path === '/welcome' && (method === 'GET' || method === 'HEAD')) {
    return view(env, 200, (nonce) => welcomePage(COPY, env, nonce));
  }
  if (path === '/intake' && method === 'POST') return renderIntake(env, await takeIntake(req, env));
  if (path === '/intake') return text('Method not allowed', 405);
  return text('Not found', 404);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await handle(req, env);
    } catch {
      return text('Server error', 500);
    }
  },
};
