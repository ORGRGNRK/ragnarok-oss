-- Runner tables: every step of the task belt (runner/) as a receipt in data's chain. Applied by
-- `./kit up` as the admin login, after brain.sql. Safe to re-run. Schema only: NO rows.
--
-- The belt (runner/conveyor, run inside a container by runner/ragnarok/belt) writes one line per
-- leg to its own logs/receipts.jsonl. The host-side wrapper copies each new line here; the
-- container never gets a database login. Every insert gets a write_log receipt (the whole line is
-- in the receipt, so it is hashed).
--   runner.runner_events   one row per belt event: a planner/critic/driver/verifier leg, a routing
--                          decision, or a person's yes/no (approve, accept, reject).
-- Rows can't be edited or deleted by the AI's login. 'proposal' is true for everything an AI
-- produced. Only a person's yes/no (approved / accepted / rejected, actor 'human:<name>') has it
-- false, and only the admin login can write such a row: the AI's login cannot even name the
-- 'proposal' column, and the CHECK ties 'human:' actors to proposal = false.
-- psql variables (set by scripts/lib.sh): rw_user, ro_user.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA IF NOT EXISTS runner;

CREATE TABLE IF NOT EXISTS runner.runner_events (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  belt        text NOT NULL,              -- which belt folder (tray) the line came from
  line_no     integer NOT NULL,           -- line number in that belt's logs/receipts.jsonl
  line_sha    text NOT NULL UNIQUE,       -- sha256 of belt + line number + line: copying twice is a no-op
  task        text NOT NULL,
  verdict     text NOT NULL,              -- e.g. plan-proposed, check-pass, verify-pass-proposed, accepted
  seat        text,                       -- planner, critic, driver, verifier, runner, human
  model       text,                       -- the local model behind an AI seat (NULL for runner/human)
  actor       text NOT NULL,              -- 'runner:<seat>' or 'human:<name>'
  proposal    boolean NOT NULL DEFAULT true,
  detail      jsonb NOT NULL DEFAULT '{}', -- the receipts.jsonl line as written by the belt
  CONSTRAINT runner_events_human_is_not_proposal CHECK ((actor LIKE 'human:%') = (NOT proposal))
);
CREATE INDEX IF NOT EXISTS runner_events_task ON runner.runner_events (task, id);
-- 2026-10-30: the model name the model API itself reported in its answers (the belt line's
-- "model_reported"), next to `model` (what the belt was configured to use). NULL for runner/human
-- rows, for seats whose output has no such field, and for every row copied before this column existed.
-- Additive: older rows and their write_log receipts are unchanged (each receipt keeps the row as it was).
ALTER TABLE runner.runner_events ADD COLUMN IF NOT EXISTS model_reported text;

DROP TRIGGER IF EXISTS trg_kit_write_log ON runner.runner_events;
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON runner.runner_events FOR EACH ROW EXECUTE FUNCTION kit_write_log();

-- The AI's read/write login (the wrapper copies belt lines with it) may READ and ADD events (always
-- proposals), never change or delete them; a person's yes is written by the admin login. The read-only login may read. NocoDB: nothing.
REVOKE ALL ON SCHEMA runner FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA runner FROM PUBLIC, :"rw_user", :"ro_user";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA runner FROM PUBLIC, :"rw_user", :"ro_user";
GRANT USAGE ON SCHEMA runner TO :"rw_user", :"ro_user";
GRANT SELECT ON runner.runner_events TO :"rw_user";
GRANT INSERT (belt, line_no, line_sha, task, verdict, seat, model, model_reported, actor, detail) ON runner.runner_events TO :"rw_user";
GRANT USAGE ON SEQUENCE runner.runner_events_id_seq TO :"rw_user";
GRANT SELECT ON runner.runner_events TO :"ro_user";

COMMIT;
