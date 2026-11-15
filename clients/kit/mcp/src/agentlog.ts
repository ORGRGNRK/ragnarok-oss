// agent_log: receipts for what an AI does on a MACHINE (shell commands, file edits, tool calls in Claude Code /
// Codex / other agents), not only what it does through this server's tools (that is access_log).
//
// The hook on each machine (hooks/agent-receipt.py) sends one JSON line per event to POST /receipts with the
// RECEIPT_TOKEN. That token can ONLY add receipts: it can't call any tool or read any data. The server writes
// each event through kit_agent_append(), the only way in: same hash chain + append-only lock as write_log and
// access_log, and kit_verify() checks all three chains.
//
// agentLogSql() is part of `./kit up` (idempotent), so clients made before this existed get it too.
import type { IncomingMessage, ServerResponse } from "node:http";
import { pool, scrub } from "./db.js";

export const MAX_EVENTS = 500;
const LIM = { short: 200, command: 8000, path: 2000 };

/** SQL (safe to re-run): the agent_log table, its chain + lock triggers, the append function, kit_verify for all chains. */
export function agentLogSql(R: { rw: string; ro: string; ui: string }): string {
  return `
-- agent_log: AI activity on machines (hooks/agent-receipt.py -> POST /receipts). Hash-chained, append-only.
CREATE TABLE IF NOT EXISTS agent_log (
  seq         bigint PRIMARY KEY,
  event_uid   text NOT NULL UNIQUE,      -- made by the hook; a re-sent event is stored once
  at          timestamptz,               -- when it happened (the machine's clock)
  host        text,                      -- machine the hook ran on (what the hook says)
  actor       text NOT NULL,             -- Claude Code / Codex / a person's shell ...
  producer    text,                      -- which hook: claude-hook, shell, log
  event       text,                      -- PostToolUse, PostToolUseFailure, command, manual ...
  tool        text,                      -- Bash, Edit, Write ...
  kind        text NOT NULL DEFAULT 'Observed' CHECK (kind IN ('Read', 'Change', 'Observed')),
  command     text,                      -- redacted (by the hook AND again by the server)
  target      text,                      -- file path or other target, if any
  cwd         text,
  session     text,
  ok          boolean,
  exit_code   integer,
  detail      jsonb,
  via         text NOT NULL,             -- what the SERVER saw: token name @ address (can't be faked by the hook)
  created_at  timestamptz NOT NULL DEFAULT now(),
  prev_hash   text NOT NULL,
  hash        text NOT NULL UNIQUE
);
CREATE INDEX IF NOT EXISTS agent_log_at ON agent_log (at DESC);
DROP TRIGGER IF EXISTS trg_agent_log_chain ON agent_log;
CREATE TRIGGER trg_agent_log_chain BEFORE INSERT ON agent_log FOR EACH ROW EXECUTE FUNCTION receipt_chain_append();
DROP TRIGGER IF EXISTS trg_agent_log_no_change ON agent_log;
CREATE TRIGGER trg_agent_log_no_change BEFORE UPDATE OR DELETE ON agent_log FOR EACH ROW EXECUTE FUNCTION receipt_reject_change();
DROP TRIGGER IF EXISTS trg_agent_log_no_truncate ON agent_log;
CREATE TRIGGER trg_agent_log_no_truncate BEFORE TRUNCATE ON agent_log FOR EACH STATEMENT EXECUTE FUNCTION receipt_reject_change();

-- The only write path into agent_log. Returns the receipt number; an event_uid already stored returns its old seq.
CREATE OR REPLACE FUNCTION kit_agent_append(p jsonb, p_via text)
RETURNS TABLE(seq bigint, is_new boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE s bigint; u text := left(coalesce(p->>'event_uid', ''), 200);
BEGIN
  IF u = '' THEN RAISE EXCEPTION 'event_uid is required' USING ERRCODE = 'invalid_parameter_value'; END IF;
  SELECT a.seq INTO s FROM agent_log a WHERE a.event_uid = u;
  IF FOUND THEN RETURN QUERY SELECT s, false; RETURN; END IF;
  INSERT INTO agent_log (event_uid, at, host, actor, producer, event, tool, kind, command, target, cwd, session, ok, exit_code, detail, via)
  VALUES (u,
          CASE WHEN p->>'at' ~ '^\\d{4}-\\d\\d-\\d\\d' THEN (p->>'at')::timestamptz END,
          left(p->>'host', 200), coalesce(nullif(left(p->>'actor', 200), ''), 'unknown'),
          left(p->>'producer', 200), left(p->>'event', 200), left(p->>'tool', 200),
          CASE WHEN p->>'kind' IN ('Read', 'Change') THEN p->>'kind' ELSE 'Observed' END,
          left(p->>'command', 8000), left(p->>'target', 2000), left(p->>'cwd', 2000), left(p->>'session', 200),
          CASE WHEN p->>'ok' IN ('true', 'false') THEN (p->>'ok')::boolean END,
          CASE WHEN p->>'exit_code' ~ '^-?\\d{1,9}$' THEN (p->>'exit_code')::int END,
          CASE WHEN jsonb_typeof(p->'detail') = 'object' THEN p->'detail' END,
          left(p_via, 300))
  RETURNING agent_log.seq INTO s;
  RETURN QUERY SELECT s, true;
END $fn$;
REVOKE ALL ON FUNCTION kit_agent_append(jsonb, text) FROM PUBLIC;
REVOKE ALL ON agent_log FROM PUBLIC, ${R.rw}, ${R.ro}, ${R.ui};
GRANT SELECT ON agent_log TO ${R.rw}, ${R.ro}, ${R.ui};
GRANT EXECUTE ON FUNCTION kit_agent_append(jsonb, text) TO ${R.rw};

-- Recompute every chain and check its lock. One row per log (agent_log included once it exists).
CREATE OR REPLACE FUNCTION kit_verify()
RETURNS TABLE(chain text, rows_checked bigint, intact boolean, first_bad_seq bigint, problem text,
              head_hash text, lock_on boolean, lock_problem text)
LANGUAGE plpgsql STABLE SET timezone = 'UTC' SET search_path = public AS $fn$
DECLARE t text; r record; exp_prev text; exp_seq bigint; n bigint; bad bigint; prob text; locks int;
BEGIN
  FOREACH t IN ARRAY ARRAY['write_log', 'access_log', 'agent_log'] LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    exp_prev := repeat('0', 64); exp_seq := 1; n := 0; bad := NULL; prob := NULL;
    FOR r IN EXECUTE format('SELECT x.seq, x.prev_hash, x.hash, to_jsonb(x) - ''hash'' - ''prev_hash'' AS content FROM %I x ORDER BY x.seq', t) LOOP
      n := n + 1;
      IF r.seq IS DISTINCT FROM exp_seq THEN
        bad := r.seq; prob := format('sequence gap: expected #%s, found #%s (a row was removed)', exp_seq, r.seq); EXIT;
      END IF;
      IF r.prev_hash IS DISTINCT FROM exp_prev THEN
        bad := r.seq; prob := 'prev_hash does not match the row before it'; EXIT;
      END IF;
      IF r.hash IS DISTINCT FROM receipt_chain_hash(r.prev_hash, r.content) THEN
        bad := r.seq; prob := 'row content does not match its hash (the row was edited)'; EXIT;
      END IF;
      exp_prev := r.hash; exp_seq := r.seq + 1;
    END LOOP;
    SELECT count(*) INTO locks FROM pg_trigger
     WHERE tgrelid = t::regclass AND tgenabled <> 'D'
       AND tgname IN ('trg_' || t || '_chain', 'trg_' || t || '_no_change', 'trg_' || t || '_no_truncate');
    chain := t; rows_checked := n; intact := bad IS NULL; first_bad_seq := bad; problem := prob;
    head_hash := CASE WHEN bad IS NULL AND n > 0 THEN exp_prev END;
    lock_on := locks = 3;
    lock_problem := CASE WHEN locks = 3 THEN NULL ELSE format('%s of 3 append-only triggers are missing or switched off', 3 - locks) END;
    RETURN NEXT;
  END LOOP;
END $fn$;
REVOKE ALL ON FUNCTION kit_verify() FROM PUBLIC;
`;
}

// Server-side redaction, on top of the hook's own: a hook on a machine might be old or edited.
const REDACT: [RegExp, string][] = [
  [/(?:\b|_)([A-Z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credentials?)[A-Z0-9_.-]*)("?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"'&;|,}]+)/gi, "$1$2[REDACTED]"],
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [REDACTED]"],
  [/(:\/\/[^/\s:@]+):[^/\s@]+@/g, "$1:[REDACTED]@"],
  [/\b(sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}|xai-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})/g, "[REDACTED]"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g, "[REDACTED PRIVATE KEY]"],
];
export function redact(s: string): string {
  let out = s;
  for (const [re, rep] of REDACT) out = out.replace(re, rep);
  return out;
}

function clean(e: Record<string, unknown>): Record<string, unknown> {
  const str = (v: unknown, n: number) => (typeof v === "string" ? v.slice(0, n) : typeof v === "number" || typeof v === "boolean" ? String(v).slice(0, n) : undefined);
  const out: Record<string, unknown> = {
    event_uid: str(e.event_uid, LIM.short), at: str(e.at, 40), host: str(e.host, LIM.short), actor: str(e.actor, LIM.short),
    producer: str(e.producer, LIM.short), event: str(e.event, LIM.short), tool: str(e.tool, LIM.short), kind: str(e.kind, 10),
    command: e.command == null ? undefined : redact(str(e.command, LIM.command) ?? ""),
    target: e.target == null ? undefined : redact(str(e.target, LIM.path) ?? ""),
    cwd: str(e.cwd, LIM.path), session: str(e.session, LIM.short),
    ok: typeof e.ok === "boolean" ? e.ok : undefined,
    exit_code: typeof e.exit_code === "number" && Number.isInteger(e.exit_code) ? e.exit_code : undefined,
  };
  if (e.detail && typeof e.detail === "object" && !Array.isArray(e.detail)) {
    const d = JSON.stringify(e.detail);
    if (d.length <= 4000) out.detail = JSON.parse(redact(d));
  }
  return out;
}

/** POST /receipts: one event object, or {"events":[...]} / an array of up to MAX_EVENTS. */
export async function handleReceipts(req: IncomingMessage, res: ServerResponse, body: unknown, via: string): Promise<void> {
  const send = (status: number, obj: unknown) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  if (req.method !== "POST") return send(405, { error: "POST only" });
  const list = Array.isArray(body) ? body : body && typeof body === "object" && Array.isArray((body as { events?: unknown }).events) ? (body as { events: unknown[] }).events : body && typeof body === "object" ? [body] : [];
  if (!list.length) return send(400, { error: "send one event object, an array, or {\"events\":[...]}" });
  if (list.length > MAX_EVENTS) return send(413, { error: `at most ${MAX_EVENTS} events per request` });
  const events = list.map((e) => (e && typeof e === "object" ? clean(e as Record<string, unknown>) : null));
  if (events.some((e) => !e || !e.event_uid)) return send(400, { error: "every event needs an event_uid" });
  const c = await pool("write").connect();
  try {
    await c.query("BEGIN");
    const logged: { event_uid: unknown; seq: number; new: boolean }[] = [];
    for (const e of events as Record<string, unknown>[]) {
      const r = (await c.query("SELECT seq, is_new FROM kit_agent_append($1::jsonb, $2)", [JSON.stringify(e), via])).rows[0];
      logged.push({ event_uid: e.event_uid, seq: Number(r.seq), new: r.is_new });
    }
    await c.query("COMMIT");
    send(200, { ok: true, logged });
  } catch (err) {
    await c.query("ROLLBACK").catch(() => undefined);
    console.error(`[client-kit] receipts error: ${scrub(err)}`);
    send(500, { error: "could not store the receipts; nothing from this request was stored" });
  } finally {
    c.release();
  }
}
