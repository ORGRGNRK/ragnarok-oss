import { getCredential, loginOptions, loginVerify, registerOptions, registerVerify } from './auth';
import type { Env } from './env';
import { html, json, randomId, safeEqual } from './http';
import { appPage, loginPage } from './pages';
import { PLAN } from './plan';
import { clearedSessionCookie, destroySession, hasSession } from './session';
import { checkHandler, getTasks, numbersHandler, rhythmHandler, stateHandler, taskHandler } from './state';

export type { Env } from './env';

/** Routes reachable without a session: the login page (GET /) and the WebAuthn endpoints. */
const PUBLIC_POST: Record<string, (req: Request, env: Env) => Promise<Response>> = {
  '/auth/register/options': registerOptions,
  '/auth/register/verify': registerVerify,
  '/auth/login/options': loginOptions,
  '/auth/login/verify': loginVerify,
};

/** Bearer token, or undefined when this request is not a machine-API attempt. */
function bearerToken(req: Request): string | undefined {
  const header = req.headers.get('authorization');
  if (!header) return undefined;
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match ? match[1] : undefined;
}

/**
 * Machine API, separate from the passkey session.
 * DAEMON_TOKEN unset: bearer calls (and every /api/check) answer 404.
 * A presented bearer is compared with safeEqual and never falls through to the cookie.
 * Decided before the browser origin check, because the daemon is not the page.
 */
async function machineApi(req: Request, env: Env, url: URL, pathname: string, method: string): Promise<Response | null> {
  if (pathname === '/api/check') {
    if (!env.DAEMON_TOKEN) return json({ ok: false, error: 'Not found' }, 404);
    const presented = bearerToken(req) ?? '';
    if (!(await safeEqual(presented, env.DAEMON_TOKEN))) return json({ ok: false, error: 'Unauthorized' }, 401);
    if (method !== 'POST') return json({ ok: false, error: 'Method not allowed' }, 405);
    return checkHandler(req, env);
  }

  if (pathname !== '/api/state' && pathname !== '/api/numbers') return null;
  const presented = bearerToken(req);
  if (presented === undefined) return null;
  if (!env.DAEMON_TOKEN) return json({ ok: false, error: 'Not found' }, 404);
  if (!(await safeEqual(presented, env.DAEMON_TOKEN))) return json({ ok: false, error: 'Unauthorized' }, 401);
  if (pathname === '/api/state' && method === 'GET') return stateHandler(url, env);
  if (pathname === '/api/numbers' && method === 'POST') return numbersHandler(req, env);
  return json({ ok: false, error: 'Method not allowed' }, 405);
}

async function handle(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const { pathname } = url;
  const method = req.method.toUpperCase();

  const machine = await machineApi(req, env, url, pathname, method);
  if (machine) return machine;

  // Every state-changing browser request must come from our own page.
  if (method !== 'GET' && method !== 'HEAD') {
    if (req.headers.get('origin') !== env.ORIGIN) return json({ ok: false, error: 'Bad origin' }, 403);
  }

  const authed = await hasSession(req, env);

  if (pathname === '/' && (method === 'GET' || method === 'HEAD')) {
    const nonce = randomId(16);
    if (!authed) return html(loginPage(nonce, (await getCredential(env)) !== null), nonce);
    return html(appPage(nonce, PLAN, await getTasks(env)), nonce);
  }

  const publicHandler = PUBLIC_POST[pathname];
  if (publicHandler) {
    if (method !== 'POST') return json({ ok: false, error: 'Method not allowed' }, 405);
    return publicHandler(req, env);
  }

  // Everything below needs a session.
  if (!authed) return json({ ok: false, error: 'Not signed in (session required)' }, 401);

  if (pathname === '/api/state' && method === 'GET') return stateHandler(url, env);
  if (method === 'POST') {
    switch (pathname) {
      case '/api/task':
        return taskHandler(req, env);
      case '/api/rhythm':
        return rhythmHandler(req, env);
      case '/api/numbers':
        return numbersHandler(req, env);
      case '/auth/logout':
        await destroySession(req, env);
        return json({ ok: true }, 200, { 'set-cookie': clearedSessionCookie() });
    }
  }
  return json({ ok: false, error: 'Not found' }, 404);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await handle(req, env);
    } catch {
      return json({ ok: false, error: 'Server error' }, 500);
    }
  },
};
