-- Phase 2: tagging/status, static facts, code-derived chain edges, summary provenance, read-only view.
-- Applied by migrate.py inside one transaction together with a change_log row.

-- 1. tagging (rows are never deleted; excluded rows are just skipped by the summarizer)
ALTER TABLE scripts ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE scripts ADD COLUMN IF NOT EXISTS catalog_status TEXT NOT NULL DEFAULT 'active';
ALTER TABLE scripts ADD COLUMN IF NOT EXISTS status_reason TEXT;
DO $$ BEGIN
  ALTER TABLE scripts ADD CONSTRAINT scripts_catalog_status_chk CHECK (catalog_status IN ('active','low_priority','excluded'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_scripts_tags ON scripts USING gin(tags);
CREATE INDEX IF NOT EXISTS idx_scripts_status ON scripts(catalog_status);

-- 2. static facts extracted by code (facts.py), one row per script, tied to the body version
CREATE TABLE IF NOT EXISTS script_facts (
  script_id         BIGINT PRIMARY KEY REFERENCES scripts(id),
  content_hash      TEXT NOT NULL,
  extractor_version TEXT NOT NULL,
  facts             JSONB NOT NULL,
  risk_code         TEXT NOT NULL CHECK (risk_code IN ('none','low','medium','high')),
  n_facts           INTEGER NOT NULL,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. script_links becomes a general edge table:
--    link_kind 'provenance' = chat <-> disk file (phase 1 rows), 'chain' = src output feeds dst input,
--    'invokes' = src runs dst.  src_id/dst_id are filled for every row.
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS id BIGSERIAL;
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS link_kind TEXT NOT NULL DEFAULT 'provenance';
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS src_id BIGINT REFERENCES scripts(id);
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS dst_id BIGINT REFERENCES scripts(id);
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS reason TEXT;
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS confidence REAL;
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS evidence JSONB;
ALTER TABLE script_links ADD COLUMN IF NOT EXISTS created_by TEXT;
ALTER TABLE script_links DROP CONSTRAINT IF EXISTS script_links_pkey;
ALTER TABLE script_links ALTER COLUMN disk_id DROP NOT NULL;
ALTER TABLE script_links ALTER COLUMN transcript_id DROP NOT NULL;
UPDATE script_links SET src_id = transcript_id, dst_id = disk_id, reason = 'chat produced disk file (' || match_type || ')',
       confidence = 1.0, created_by = 'load.py' WHERE link_kind = 'provenance' AND src_id IS NULL;
ALTER TABLE script_links ALTER COLUMN src_id SET NOT NULL;
ALTER TABLE script_links ALTER COLUMN dst_id SET NOT NULL;
DO $$ BEGIN
  ALTER TABLE script_links ADD PRIMARY KEY (id);
EXCEPTION WHEN invalid_table_definition THEN NULL; END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_script_links ON script_links(link_kind, src_id, dst_id, match_type);
CREATE INDEX IF NOT EXISTS idx_links_src ON script_links(src_id);
CREATE INDEX IF NOT EXISTS idx_links_dst ON script_links(dst_id);
DO $$ BEGIN
  ALTER TABLE script_links ADD CONSTRAINT script_links_kind_chk CHECK (link_kind IN ('provenance','chain','invokes'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 4. summary provenance
ALTER TABLE summaries ADD COLUMN IF NOT EXISTS truncated BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE summaries ADD COLUMN IF NOT EXISTS facts_version TEXT;
ALTER TABLE summaries ADD COLUMN IF NOT EXISTS input_chars INTEGER;

-- 5. latest valid summary per script + effective risk (max of model risk and code-detected risk)
CREATE OR REPLACE VIEW catalog_v AS
SELECT s.id, s.catalog_key, s.source, s.source_tools, s.kind, s.project, s.path, s.language, s.lines,
       s.tags, s.catalog_status, s.status_reason, s.first_seen, s.last_seen, s.version_count, s.occurrence_count,
       s.partial, s.secrets_redacted, length(s.body_redacted) AS chars,
       m.id AS summary_id, m.name, m.purpose, m.inputs, m.outputs, m.dependencies, m.side_effects,
       m.risk AS risk_model, m.reuse_notes, m.pipes_into, m.model, m.prompt_version, m.truncated, m.created_at AS summarized_at,
       (m.content_hash IS DISTINCT FROM s.content_hash) AS summary_stale,
       f.risk_code, f.facts, f.n_facts,
       CASE GREATEST(array_position(ARRAY['none','low','medium','high'], m.risk),
                     array_position(ARRAY['none','low','medium','high'], f.risk_code))
         WHEN 1 THEN 'none' WHEN 2 THEN 'low' WHEN 3 THEN 'medium' WHEN 4 THEN 'high' END AS risk
FROM scripts s
LEFT JOIN LATERAL (SELECT * FROM summaries x WHERE x.script_id = s.id AND x.valid_json
                   ORDER BY (x.content_hash = s.content_hash) DESC, x.prompt_version DESC, x.created_at DESC LIMIT 1) m ON true
LEFT JOIN script_facts f ON f.script_id = s.id;
