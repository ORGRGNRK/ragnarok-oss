-- script_catalog: every script found in the owner's AI chat transcripts and on disk.
-- Owner role: script_catalog. change_log is append-only (hash chained, triggers refuse UPDATE/DELETE/TRUNCATE).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS scripts (
  id                    BIGSERIAL PRIMARY KEY,
  catalog_key           TEXT NOT NULL UNIQUE,      -- path:<abs path> | hash:<sha256> | disk:<sha256>
  source                TEXT NOT NULL CHECK (source IN ('transcript','disk')),
  source_tools          TEXT[] NOT NULL DEFAULT '{}', -- claude-code, localai, codex, disk
  kind                  TEXT,                       -- write, edit, heredoc, fence, bash_cmd, edit_fragment, file
  project               TEXT,
  path                  TEXT,
  alt_paths             TEXT[] NOT NULL DEFAULT '{}',
  language              TEXT,
  lines                 INTEGER,
  content_hash          TEXT NOT NULL,              -- sha256 of normalized, redacted body
  body_redacted         TEXT NOT NULL,
  secrets_redacted      INTEGER NOT NULL DEFAULT 0,
  partial               BOOLEAN NOT NULL DEFAULT false, -- true = only an edit fragment was recoverable
  first_seen            TIMESTAMPTZ,
  last_seen             TIMESTAMPTZ,
  version_count         INTEGER NOT NULL DEFAULT 1,
  occurrence_count      INTEGER NOT NULL DEFAULT 1,
  sessions              TEXT[] NOT NULL DEFAULT '{}',
  linked_transcript_ids BIGINT[] NOT NULL DEFAULT '{}',
  linked_disk_ids       BIGINT[] NOT NULL DEFAULT '{}',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_scripts_hash ON scripts(content_hash);
CREATE INDEX IF NOT EXISTS idx_scripts_lang ON scripts(language);
CREATE INDEX IF NOT EXISTS idx_scripts_project ON scripts(project);

-- every raw sighting (no body): which chat / file produced which version
CREATE TABLE IF NOT EXISTS occurrences (
  id           BIGSERIAL PRIMARY KEY,
  script_id    BIGINT NOT NULL REFERENCES scripts(id),
  source_tool  TEXT NOT NULL,
  kind         TEXT,
  source_file  TEXT,
  session_id   TEXT,
  ts           TIMESTAMPTZ,
  path         TEXT,
  content_hash TEXT NOT NULL,
  lines        INTEGER,
  partial      BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_occ_script ON occurrences(script_id);
CREATE INDEX IF NOT EXISTS idx_occ_hash ON occurrences(content_hash);

CREATE TABLE IF NOT EXISTS script_links (
  disk_id       BIGINT NOT NULL REFERENCES scripts(id),
  transcript_id BIGINT NOT NULL REFERENCES scripts(id),
  match_type    TEXT NOT NULL,                      -- hash | path | hash+path
  PRIMARY KEY (disk_id, transcript_id)
);

CREATE TABLE IF NOT EXISTS summaries (
  id            BIGSERIAL PRIMARY KEY,
  script_id     BIGINT NOT NULL REFERENCES scripts(id),
  content_hash  TEXT NOT NULL,                      -- body version that was summarized
  model         TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  name          TEXT,
  purpose       TEXT,
  inputs        JSONB,
  outputs       JSONB,
  dependencies  JSONB,
  side_effects  JSONB,
  risk          TEXT,
  reuse_notes   TEXT,
  pipes_into    JSONB,
  raw_reply     TEXT,
  valid_json    BOOLEAN NOT NULL,
  attempts      INTEGER NOT NULL,
  latency_ms    INTEGER,
  run_label     TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_summaries_script ON summaries(script_id);

-- append-only change log, same design as ragnarok-pipe's processing_log
CREATE TABLE IF NOT EXISTS change_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seq         BIGINT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor       TEXT NOT NULL,
  action      TEXT NOT NULL,          -- schema_create, load, summarize, ...
  script_id   BIGINT,
  ok          BOOLEAN,
  detail      JSONB,
  prev_hash   TEXT NOT NULL UNIQUE,
  hash        TEXT NOT NULL UNIQUE
);

CREATE OR REPLACE FUNCTION log_chain_hash(prev_hash text, content jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT encode(digest(prev_hash || E'\n' || content::text, 'sha256'), 'hex')
$$;

CREATE OR REPLACE FUNCTION change_log_append() RETURNS trigger
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE last_seq bigint; last_hash text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('script_catalog_log_chain'));
  SELECT seq, hash INTO last_seq, last_hash FROM change_log ORDER BY seq DESC LIMIT 1;
  NEW.seq        := COALESCE(last_seq, 0) + 1;
  NEW.prev_hash  := COALESCE(last_hash, repeat('0', 64));
  NEW.created_at := now();
  NEW.hash       := NULL;
  NEW.hash       := log_chain_hash(NEW.prev_hash, to_jsonb(NEW) - 'hash' - 'prev_hash');
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION change_log_reject() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'change_log is append-only: % is not allowed', TG_OP USING ERRCODE = 'insufficient_privilege';
END $$;

DROP TRIGGER IF EXISTS change_log_append ON change_log;
DROP TRIGGER IF EXISTS change_log_no_update ON change_log;
DROP TRIGGER IF EXISTS change_log_no_truncate ON change_log;
CREATE TRIGGER change_log_append BEFORE INSERT ON change_log FOR EACH ROW EXECUTE FUNCTION change_log_append();
CREATE TRIGGER change_log_no_update BEFORE UPDATE OR DELETE ON change_log FOR EACH ROW EXECUTE FUNCTION change_log_reject();
CREATE TRIGGER change_log_no_truncate BEFORE TRUNCATE ON change_log FOR EACH STATEMENT EXECUTE FUNCTION change_log_reject();

CREATE OR REPLACE FUNCTION change_log_verify()
RETURNS TABLE(bad_seq bigint, reason text)
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE r record; expect_prev text := repeat('0', 64); expect_seq bigint := 1; h text;
BEGIN
  FOR r IN SELECT * FROM change_log ORDER BY seq LOOP
    IF r.seq <> expect_seq THEN bad_seq := r.seq; reason := 'gap in seq'; RETURN NEXT; RETURN; END IF;
    IF r.prev_hash <> expect_prev THEN bad_seq := r.seq; reason := 'prev_hash mismatch'; RETURN NEXT; RETURN; END IF;
    h := log_chain_hash(r.prev_hash, to_jsonb(r) - 'hash' - 'prev_hash');
    IF h <> r.hash THEN bad_seq := r.seq; reason := 'hash mismatch (row altered)'; RETURN NEXT; RETURN; END IF;
    expect_prev := r.hash; expect_seq := r.seq + 1;
  END LOOP;
END $$;
