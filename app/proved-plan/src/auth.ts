import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import type {
  AuthenticationResponseJSON,
  AuthenticatorTransportFuture,
  RegistrationResponseJSON,
} from '@simplewebauthn/server';
import type { Env } from './env';
import { b64url, fromB64url, json, randomId, readJson, safeEqual } from './http';
import { createSession } from './session';

/** The single owner credential, stored under CRED_KEY. */
export interface StoredCredential {
  id: string;
  publicKey: string; // base64url COSE key
  counter: number;
  transports?: AuthenticatorTransportFuture[];
  createdAt: number;
}

export const CRED_KEY = 'cred:owner';
export const CHALLENGE_TTL_SECONDS = 300;
const MIN_SETUP_TOKEN_LENGTH = 16;
const FLOW_ID = /^[A-Za-z0-9_-]{22,64}$/;

/** What every registration must use: Touch ID / Secure Enclave style passkey with UV. */
export const AUTHENTICATOR_SELECTION = {
  authenticatorAttachment: 'platform',
  userVerification: 'required',
  residentKey: 'required',
  requireResidentKey: true,
} as const;

export async function getCredential(env: Env): Promise<StoredCredential | null> {
  const raw = await env.PLAN_KV.get(CRED_KEY);
  return raw ? (JSON.parse(raw) as StoredCredential) : null;
}

function refuse(status: number, error: string): Response {
  return json({ ok: false, error }, status);
}

/** Setup is allowed only while no credential exists and the right SETUP_TOKEN is given. */
async function setupAllowed(env: Env, token: unknown): Promise<Response | null> {
  if (await getCredential(env)) return refuse(403, 'A passkey is already registered. Registration is closed.');
  const secret = env.SETUP_TOKEN;
  if (!secret || secret.length < MIN_SETUP_TOKEN_LENGTH) return refuse(403, 'Setup is disabled (no SETUP_TOKEN secret).');
  if (typeof token !== 'string' || !(await safeEqual(token, secret))) return refuse(403, 'Wrong setup token.');
  return null;
}

/** Fetch a one-time challenge and delete it so it can never be used twice. */
async function takeChallenge(env: Env, kind: 'reg' | 'auth', flowId: unknown): Promise<string | null> {
  if (typeof flowId !== 'string' || !FLOW_ID.test(flowId)) return null;
  const key = `chal:${kind}:${flowId}`;
  const challenge = await env.PLAN_KV.get(key);
  if (challenge === null) return null;
  await env.PLAN_KV.delete(key);
  return challenge;
}

export async function registerOptions(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body) return refuse(400, 'Expected a JSON body.');
  const denied = await setupAllowed(env, body.token);
  if (denied) return denied;

  const options = await generateRegistrationOptions({
    rpName: env.RP_NAME ?? 'Proved plan',
    rpID: env.RP_ID,
    userName: 'owner',
    userDisplayName: 'Plan owner',
    attestationType: 'none',
    authenticatorSelection: { ...AUTHENTICATOR_SELECTION },
    preferredAuthenticatorType: 'localDevice',
    supportedAlgorithmIDs: [-7, -257],
  });
  const flowId = randomId(24);
  await env.PLAN_KV.put(`chal:reg:${flowId}`, options.challenge, { expirationTtl: CHALLENGE_TTL_SECONDS });
  return json({ ok: true, flowId, options });
}

export async function registerVerify(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body) return refuse(400, 'Expected a JSON body.');
  const denied = await setupAllowed(env, body.token);
  if (denied) return denied;

  const expectedChallenge = await takeChallenge(env, 'reg', body.flowId);
  if (!expectedChallenge) return refuse(400, 'Unknown or expired challenge. Start again.');

  const response = body.response as RegistrationResponseJSON | undefined;
  if (!response || typeof response !== 'object') return refuse(400, 'Missing credential.');
  if (response.authenticatorAttachment !== 'platform') {
    return refuse(400, 'Only a platform authenticator (Touch ID / Face ID on this device) is accepted.');
  }

  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge,
      expectedOrigin: env.ORIGIN,
      expectedRPID: env.RP_ID,
      requireUserVerification: true,
      supportedAlgorithmIDs: [-7, -257],
    });
  } catch {
    return refuse(400, 'Passkey registration could not be verified.');
  }
  if (!verification.verified || !verification.registrationInfo) {
    return refuse(400, 'Passkey registration could not be verified.');
  }
  // Re-check right before writing: never overwrite an existing owner credential.
  if (await getCredential(env)) return refuse(403, 'A passkey is already registered. Registration is closed.');

  const { credential } = verification.registrationInfo;
  const stored: StoredCredential = {
    id: credential.id,
    publicKey: b64url(credential.publicKey),
    counter: credential.counter,
    transports: credential.transports ?? response.response.transports,
    createdAt: Date.now(),
  };
  await env.PLAN_KV.put(CRED_KEY, JSON.stringify(stored));
  const cookie = await createSession(env);
  return json({ ok: true }, 200, { 'set-cookie': cookie });
}

export async function loginOptions(_req: Request, env: Env): Promise<Response> {
  const cred = await getCredential(env);
  if (!cred) return refuse(409, 'No passkey registered yet.');
  const options = await generateAuthenticationOptions({
    rpID: env.RP_ID,
    allowCredentials: [{ id: cred.id, transports: cred.transports }],
    userVerification: 'required',
  });
  const flowId = randomId(24);
  await env.PLAN_KV.put(`chal:auth:${flowId}`, options.challenge, { expirationTtl: CHALLENGE_TTL_SECONDS });
  return json({ ok: true, flowId, options: { ...options, hints: ['client-device'] } });
}

export async function loginVerify(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body) return refuse(400, 'Expected a JSON body.');
  const cred = await getCredential(env);
  if (!cred) return refuse(409, 'No passkey registered yet.');

  const expectedChallenge = await takeChallenge(env, 'auth', body.flowId);
  if (!expectedChallenge) return refuse(401, 'Unknown, used or expired challenge. Start again.');

  const response = body.response as AuthenticationResponseJSON | undefined;
  if (!response || typeof response !== 'object' || response.id !== cred.id) return refuse(401, 'Unknown passkey.');
  if (response.authenticatorAttachment !== 'platform') {
    return refuse(401, 'Only a platform authenticator (Touch ID / Face ID on this device) is accepted.');
  }

  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge,
      expectedOrigin: env.ORIGIN,
      expectedRPID: env.RP_ID,
      credential: { id: cred.id, publicKey: fromB64url(cred.publicKey), counter: cred.counter, transports: cred.transports },
      requireUserVerification: true,
    });
  } catch {
    return refuse(401, 'Passkey sign-in could not be verified.');
  }
  if (!verification.verified) return refuse(401, 'Passkey sign-in could not be verified.');

  const newCounter = verification.authenticationInfo.newCounter;
  if (newCounter !== cred.counter) {
    await env.PLAN_KV.put(CRED_KEY, JSON.stringify({ ...cred, counter: newCounter }));
  }
  const cookie = await createSession(env);
  return json({ ok: true }, 200, { 'set-cookie': cookie });
}
