import type { Env } from './env';
import { json, readJson } from './http';
import { NUMBER_KEYS, RHYTHM_IDS, TASK_IDS } from './plan';

export const TASKS_KEY = 'state:tasks';
const DAY = /^(\d{4})-(\d{2})-(\d{2})$/;
const MAX_NUMBER = 1_000_000;

export interface DayState {
  rhythm: Record<string, boolean>;
  numbers: Record<string, number>;
}

/** A calendar day (the phone/Mac's local date), e.g. 2026-11-07. */
export function validDay(v: unknown): v is string {
  if (typeof v !== 'string') return false;
  const m = DAY.exec(v);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!));
  return d.toISOString().slice(0, 10) === v;
}

async function readObject<T>(env: Env, key: string, fallback: T): Promise<T> {
  const raw = await env.PLAN_KV.get(key);
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function getTasks(env: Env): Promise<Record<string, boolean>> {
  return readObject<Record<string, boolean>>(env, TASKS_KEY, {});
}

export function getDay(env: Env, day: string): Promise<DayState> {
  return readObject<DayState>(env, `day:${day}`, { rhythm: {}, numbers: {} });
}

export async function stateHandler(url: URL, env: Env): Promise<Response> {
  const day = url.searchParams.get('day');
  if (!validDay(day)) return json({ ok: false, error: 'day=YYYY-MM-DD required' }, 400);
  const [tasks, today] = await Promise.all([getTasks(env), getDay(env, day)]);
  return json({ ok: true, day, tasks, rhythm: today.rhythm, numbers: today.numbers });
}

/** Same KV write the day-task checkbox uses. */
export async function setTaskDone(env: Env, id: string, done: boolean): Promise<Record<string, boolean>> {
  const tasks = await getTasks(env);
  if (done) tasks[id] = true;
  else delete tasks[id];
  await env.PLAN_KV.put(TASKS_KEY, JSON.stringify(tasks));
  return tasks;
}

/** Same KV write the daily-rhythm checkbox uses. */
export async function setRhythmDone(env: Env, day: string, id: string, done: boolean): Promise<Record<string, boolean>> {
  const state = await getDay(env, day);
  if (done) state.rhythm[id] = true;
  else delete state.rhythm[id];
  await env.PLAN_KV.put(`day:${day}`, JSON.stringify(state));
  return state.rhythm;
}

export async function taskHandler(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body || typeof body.id !== 'string' || !TASK_IDS.has(body.id) || typeof body.done !== 'boolean') {
    return json({ ok: false, error: 'Expected {id, done}' }, 400);
  }
  const tasks = await setTaskDone(env, body.id, body.done);
  return json({ ok: true, tasks });
}

export async function rhythmHandler(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body || !validDay(body.day) || typeof body.id !== 'string' || !RHYTHM_IDS.has(body.id) || typeof body.done !== 'boolean') {
    return json({ ok: false, error: 'Expected {day, id, done}' }, 400);
  }
  const rhythm = await setRhythmDone(env, body.day, body.id, body.done);
  return json({ ok: true, rhythm });
}

/**
 * Machine-API mirror of the page checkboxes.
 * A day-task id is `{id, done}` (same as POST /api/task).
 * A rhythm id is `{day, id, done}` (same as POST /api/rhythm).
 */
export async function checkHandler(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body || typeof body.id !== 'string' || typeof body.done !== 'boolean') {
    return json({ ok: false, error: 'Expected {id, done}' }, 400);
  }
  if (TASK_IDS.has(body.id)) {
    const tasks = await setTaskDone(env, body.id, body.done);
    return json({ ok: true, tasks });
  }
  if (RHYTHM_IDS.has(body.id)) {
    if (!validDay(body.day)) return json({ ok: false, error: 'Expected {day, id, done}' }, 400);
    const rhythm = await setRhythmDone(env, body.day, body.id, body.done);
    return json({ ok: true, rhythm });
  }
  return json({ ok: false, error: 'Unknown id' }, 400);
}

export async function numbersHandler(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  if (!body || !validDay(body.day) || !body.numbers || typeof body.numbers !== 'object' || Array.isArray(body.numbers)) {
    return json({ ok: false, error: 'Expected {day, numbers}' }, 400);
  }
  const incoming = body.numbers as Record<string, unknown>;
  const clean: Record<string, number> = {};
  for (const [k, v] of Object.entries(incoming)) {
    if (!NUMBER_KEYS.has(k)) return json({ ok: false, error: `Unknown number: ${k}` }, 400);
    if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > MAX_NUMBER) {
      return json({ ok: false, error: `${k} must be a whole number 0–${MAX_NUMBER}` }, 400);
    }
    clean[k] = v;
  }
  const state = await getDay(env, body.day);
  state.numbers = { ...state.numbers, ...clean };
  await env.PLAN_KV.put(`day:${body.day}`, JSON.stringify(state));
  return json({ ok: true, numbers: state.numbers });
}
