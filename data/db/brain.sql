-- Brain tables: fix-memory (past test failures and the change that fixed them). Applied by
-- `./kit up` as the admin login, after business.sql. Safe to re-run. Schema only: NO rows.
--
-- Comes from ~/Developer/fix-memory fixloop/schema.sql, changed so ONE Postgres holds everything
-- and the receipts are data/'s hash-chained write_log (no separate `receipts` table):
--   brain.brain_fixes        one row per learned fix. Every insert gets a write_log receipt
--                            (full error text, cause and diff are in the receipt, so they are hashed).
--   brain.brain_fix_events   things that happened to a fix: 'fix_reused' (a stored fix healed a new
--                            failure as-is), 'reembed'. Every insert gets a write_log receipt.
--   brain.fix_vectors        the search vectors (pgvector). Derived from the error text and
--                            rebuildable, so NOT receipted (same as fix-memory: embeddings were never
--                            part of a receipt).
-- Nothing can be edited or deleted except the vectors (rebuilt by `fixloop reembed`); only the admin
-- could delete, and that too would be receipted.
-- psql variables (set by scripts/lib.sh): rw_user, ro_user.
\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS brain;

CREATE TABLE IF NOT EXISTS brain.brain_fixes (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  source      text NOT NULL,              -- 'loop' (learned by fixloop), 'mcp', 'seed:demo_median', ...
  project     text,
  error_text  text NOT NULL,              -- normalized failing test output
  cause       text,
  fix         text NOT NULL,              -- unified diff of the change that made the tests pass
  detail      jsonb NOT NULL DEFAULT '{}' -- tries, test command, model used, ...
);
CREATE TABLE IF NOT EXISTS brain.brain_fix_events (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  kind        text NOT NULL CHECK (kind IN ('fix_reused', 'reembed')),
  fix_id      bigint REFERENCES brain.brain_fixes(id),
  project     text,
  detail      jsonb NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS brain.fix_vectors (
  fix_id      bigint PRIMARY KEY REFERENCES brain.brain_fixes(id),
  embedding   vector(768) NOT NULL,       -- nomic-embed-text of the error signature
  embed_model text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fix_vectors_hnsw ON brain.fix_vectors USING hnsw (embedding vector_cosine_ops);

DROP TRIGGER IF EXISTS trg_kit_write_log ON brain.brain_fixes;
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON brain.brain_fixes FOR EACH ROW EXECUTE FUNCTION kit_write_log();
DROP TRIGGER IF EXISTS trg_kit_write_log ON brain.brain_fix_events;
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON brain.brain_fix_events FOR EACH ROW EXECUTE FUNCTION kit_write_log();

-- Who may do what. The AI's read/write login (fixloop uses it) may READ and ADD fixes and events,
-- never change or delete them; it may rebuild vectors. The read-only login may read. NocoDB: nothing.
REVOKE ALL ON SCHEMA brain FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA brain FROM PUBLIC, :"rw_user", :"ro_user";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA brain FROM PUBLIC, :"rw_user", :"ro_user";
GRANT USAGE ON SCHEMA brain TO :"rw_user", :"ro_user";
GRANT SELECT, INSERT ON brain.brain_fixes, brain.brain_fix_events TO :"rw_user";
GRANT USAGE ON SEQUENCE brain.brain_fixes_id_seq, brain.brain_fix_events_id_seq TO :"rw_user";
GRANT SELECT, INSERT, UPDATE ON brain.fix_vectors TO :"rw_user";
GRANT SELECT ON brain.brain_fixes, brain.brain_fix_events, brain.fix_vectors TO :"ro_user";

COMMIT;
