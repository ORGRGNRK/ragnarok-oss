-- Memory layer: what the AIs remember about the owner, the machines and the rules, in three layers.
-- Applied by `./kit up` as the admin login, after brain.sql. Safe to re-run. Schema only: NO rows.
--
--   CORE      memory.core view: the CURRENT facts whose status is Verified or Timeless. Boot shows only
--             their titles (an index, kept under the 10,000-character hook limit); full text on demand.
--             (the owner's rules: boot loads only Verified + Timeless; "the index is not the thing";
--             retrieval is two passes, know it exists, then find it.)
--   ARCHIVAL  memory.facts: every version of every fact, with the dates it was true (valid_from /
--             valid_to). A changed fact is a NEW version; the old one gets valid_to and stays, so
--             nothing is lost and "what did we believe on 10-20" can be answered. Never deleted.
--   RECALL    past conversations and files: the nomic-vector corpus searched by search-fast.py
--             (Heimdall corpus on the Mac). Not copied in here; scripts/memory.py searches both.
--
-- Status (from the Yggdrasil memory checker): Unchecked (new or imported, not in core), Verified (a check
-- passed), Timeless (true by nature, e.g. history), Stale (a check failed; kept, not in core).
-- Who may do what:
--   AI read/write login: read; add or change a fact ONLY through memory.remember(), which always lands
--                        as Unchecked. It cannot promote, retire, edit history or delete.
--   AI read-only login:  read.
--   admin (a person, the checker, importers): memory.import_fact, memory.set_status, memory.retire.
-- Every row change gets a write_log receipt (who, old value, new value).
-- psql variables (set by scripts/lib.sh): rw_user, ro_user.
\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS memory;

CREATE TABLE IF NOT EXISTS memory.facts (
  id             bigserial PRIMARY KEY,
  fact_key       text NOT NULL,              -- stable name across versions: 'ygg:57', 'claude:user-location', 'chris:...'
  version        int  NOT NULL,
  title          text NOT NULL,
  kind           text,                       -- the owner / Rule / Feedback / Reference / Project / user / feedback ...
  description    text,                       -- one or two lines
  body           text NOT NULL,
  status         text NOT NULL DEFAULT 'Unchecked' CHECK (status IN ('Unchecked', 'Verified', 'Timeless', 'Stale')),
  checks         text,                       -- how a checker can test it (paths, services, commands)
  last_verified  timestamptz,
  valid_from     timestamptz NOT NULL DEFAULT now(),
  valid_to       timestamptz,                -- NULL = current
  superseded_by  bigint REFERENCES memory.facts(id),
  source         text NOT NULL,              -- where it came from: 'ygg_ragnarok_core.Memories#57 (ygg-scratch)', 'mcp', ...
  actor          text NOT NULL,              -- who wrote this version
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fact_key, version),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS facts_one_current ON memory.facts (fact_key) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS facts_status ON memory.facts (status) WHERE valid_to IS NULL;

CREATE TABLE IF NOT EXISTS memory.fact_vectors (
  fact_id     bigint PRIMARY KEY REFERENCES memory.facts(id),
  embedding   vector(768) NOT NULL,          -- nomic-embed-text of title + description + body
  embed_model text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fact_vectors_hnsw ON memory.fact_vectors USING hnsw (embedding vector_cosine_ops);

CREATE OR REPLACE VIEW memory.current AS
  SELECT * FROM memory.facts WHERE valid_to IS NULL;
CREATE OR REPLACE VIEW memory.core AS
  SELECT id, fact_key, title, kind, status, last_verified, valid_from
    FROM memory.facts WHERE valid_to IS NULL AND status IN ('Verified', 'Timeless');

DROP TRIGGER IF EXISTS trg_kit_write_log ON memory.facts;
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON memory.facts FOR EACH ROW EXECUTE FUNCTION kit_write_log();

-- Shared by remember/import: close the current version (if any, and if different) and add the next one.
CREATE OR REPLACE FUNCTION memory._put(p_key text, p_title text, p_kind text, p_desc text, p_body text,
    p_status text, p_checks text, p_last_verified timestamptz, p_valid_from timestamptz, p_source text, p_actor text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = memory, public AS $$
DECLARE cur memory.facts; new_id bigint; t timestamptz := COALESCE(p_valid_from, now());
BEGIN
  IF coalesce(trim(p_key), '') = '' OR coalesce(trim(p_title), '') = '' OR coalesce(trim(p_body), '') = '' THEN
    RAISE EXCEPTION 'memory: key, title and body are required';
  END IF;
  PERFORM set_config('receipt.actor', p_actor, true);
  SELECT * INTO cur FROM memory.facts WHERE fact_key = p_key AND valid_to IS NULL FOR UPDATE;
  IF FOUND AND cur.title = p_title AND cur.body = p_body AND cur.description IS NOT DISTINCT FROM p_desc
     AND cur.kind IS NOT DISTINCT FROM p_kind THEN
    RETURN cur.id;                                    -- nothing changed: no new version
  END IF;
  IF FOUND AND t < cur.valid_from THEN t := now(); END IF;
  IF FOUND THEN UPDATE memory.facts SET valid_to = t WHERE id = cur.id; END IF;
  INSERT INTO memory.facts (fact_key, version, title, kind, description, body, status, checks, last_verified,
                            valid_from, source, actor)
  VALUES (p_key, COALESCE(cur.version, 0) + 1, p_title, p_kind, p_desc, p_body, p_status,
          COALESCE(p_checks, cur.checks), p_last_verified, t, p_source, p_actor)
  RETURNING id INTO new_id;
  IF FOUND THEN NULL; END IF;
  IF cur.id IS NOT NULL THEN UPDATE memory.facts SET superseded_by = new_id WHERE id = cur.id; END IF;
  RETURN new_id;
END $$;

-- What an AI may call: a new or changed fact, always Unchecked until a checker or a person promotes it.
CREATE OR REPLACE FUNCTION memory.remember(p_key text, p_title text, p_body text, p_kind text DEFAULT NULL,
    p_desc text DEFAULT NULL, p_source text DEFAULT 'mcp', p_actor text DEFAULT NULL)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = memory, public AS $$
  SELECT memory._put(p_key, p_title, p_kind, p_desc, p_body, 'Unchecked', NULL, NULL, NULL, p_source,
                     COALESCE(NULLIF(p_actor, ''), session_user));
$$;

-- Admin only: imports keep the status and dates they had in the source.
CREATE OR REPLACE FUNCTION memory.import_fact(p_key text, p_title text, p_kind text, p_desc text, p_body text,
    p_status text, p_checks text, p_last_verified timestamptz, p_valid_from timestamptz, p_source text, p_actor text)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = memory, public AS $$
  SELECT memory._put(p_key, p_title, p_kind, p_desc, p_body, p_status, p_checks, p_last_verified, p_valid_from,
                     p_source, p_actor);
$$;

-- Admin only (the checker or a person): promote / demote the current version.
CREATE OR REPLACE FUNCTION memory.set_status(p_key text, p_status text, p_actor text, p_checks text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = memory, public AS $$
DECLARE fid bigint;
BEGIN
  PERFORM set_config('receipt.actor', p_actor, true);
  UPDATE memory.facts SET status = p_status, checks = COALESCE(p_checks, checks),
         last_verified = CASE WHEN p_status = 'Verified' THEN now() ELSE last_verified END
   WHERE fact_key = p_key AND valid_to IS NULL RETURNING id INTO fid;
  IF fid IS NULL THEN RAISE EXCEPTION 'memory: no current fact %', p_key; END IF;
  RETURN fid;
END $$;

-- Admin only: a fact that stopped being true. It keeps its text; it just gets an end date.
CREATE OR REPLACE FUNCTION memory.retire(p_key text, p_actor text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = memory, public AS $$
DECLARE fid bigint;
BEGIN
  PERFORM set_config('receipt.actor', p_actor, true);
  UPDATE memory.facts SET valid_to = now() WHERE fact_key = p_key AND valid_to IS NULL RETURNING id INTO fid;
  IF fid IS NULL THEN RAISE EXCEPTION 'memory: no current fact %', p_key; END IF;
  RETURN fid;
END $$;

-- the owner's own words: what they typed to the AIs (Claude Code transcripts first), verbatim, with when and where.
-- Part of RECALL: how he actually talks, so a model can match his phrasing. Read-only to the AI logins;
-- only the importer (admin) adds rows. Rows are never edited; a re-import skips what is already here.
CREATE TABLE IF NOT EXISTS memory.words (
  id          bigserial PRIMARY KEY,
  said_at     timestamptz NOT NULL,
  text        text NOT NULL,
  source      text NOT NULL,                 -- 'claude-code'
  session     text,
  project     text,
  text_hash   text NOT NULL UNIQUE,          -- md5 of the text: the same message twice is stored once
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS words_said_at ON memory.words (said_at);
CREATE TABLE IF NOT EXISTS memory.word_vectors (
  word_id     bigint PRIMARY KEY REFERENCES memory.words(id),
  embedding   vector(768) NOT NULL,
  embed_model text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS word_vectors_hnsw ON memory.word_vectors USING hnsw (embedding vector_cosine_ops);

REVOKE ALL ON SCHEMA memory FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA memory FROM PUBLIC, :"rw_user", :"ro_user";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA memory FROM PUBLIC, :"rw_user", :"ro_user";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA memory FROM PUBLIC, :"rw_user", :"ro_user";
GRANT USAGE ON SCHEMA memory TO :"rw_user", :"ro_user";
GRANT SELECT ON memory.facts, memory.fact_vectors, memory.current, memory.core, memory.words, memory.word_vectors TO :"rw_user", :"ro_user";
GRANT EXECUTE ON FUNCTION memory.remember(text, text, text, text, text, text, text) TO :"rw_user";
-- the vectors are derived (rebuildable), so the AI login may refresh them
GRANT INSERT, UPDATE ON memory.fact_vectors TO :"rw_user";
COMMIT;
