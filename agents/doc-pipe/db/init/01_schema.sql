-- Ragnarok pipe: documents read from photos by a local vision model.
-- Owner role = POSTGRES_USER (pipe_admin). The web app connects as pipe_app, which can
-- read/write documents and line_items but can only INSERT/SELECT the processing log.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE documents (
  id             BIGSERIAL PRIMARY KEY,
  uploaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by    TEXT,
  filename       TEXT,
  sha256         TEXT NOT NULL,
  image_path     TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'processing'
                 CHECK (status IN ('processing','ok','needs_review','approved','failed')),
  doc_type       TEXT,
  vendor         TEXT,
  doc_date       DATE,
  subtotal       NUMERIC(14,2),
  tax            NUMERIC(14,2),
  total          NUMERIC(14,2),
  currency       TEXT,
  language       TEXT,
  raw_text       TEXT,
  extracted_json JSONB,
  model          TEXT,
  model_confidence NUMERIC(4,3),
  latency_ms     INTEGER,
  errors         JSONB NOT NULL DEFAULT '[]'::jsonb,
  reviewed_at    TIMESTAMPTZ,
  reviewed_by    TEXT,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_documents_sha256 ON documents(sha256);
CREATE INDEX idx_documents_status ON documents(status);

CREATE TABLE line_items (
  id           BIGSERIAL PRIMARY KEY,
  document_id  BIGINT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  position     INTEGER NOT NULL,
  description  TEXT,
  qty          NUMERIC(14,3),
  unit_price   NUMERIC(14,2),
  amount       NUMERIC(14,2)
);
CREATE INDEX idx_line_items_doc ON line_items(document_id);

-- ------------------------------------------------------------ append-only log
-- Same idea as the postgres-nocodb-receipted kit: every row gets seq / prev_hash / hash at
-- INSERT time inside the database; UPDATE, DELETE and TRUNCATE are rejected by triggers.
-- document_id is deliberately NOT a foreign key so the log survives anything done to documents.
CREATE TABLE processing_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seq          BIGINT NOT NULL UNIQUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor        TEXT NOT NULL,          -- who: tailscale login / basic-auth user / 'pipeline'
  document_id  BIGINT,
  step         TEXT NOT NULL,          -- what: upload, prepare_image, model_call, validate, store, review
  model        TEXT,
  ok           BOOLEAN,
  result       TEXT,
  detail       JSONB,
  prev_hash    TEXT NOT NULL UNIQUE,
  hash         TEXT NOT NULL UNIQUE
);
CREATE INDEX idx_processing_log_doc ON processing_log(document_id);

CREATE FUNCTION log_chain_hash(prev_hash text, content jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT encode(digest(prev_hash || E'\n' || content::text, 'sha256'), 'hex')
$$;

CREATE FUNCTION log_chain_append() RETURNS trigger
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE last_seq bigint; last_hash text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pipe_log_chain'));
  SELECT seq, hash INTO last_seq, last_hash FROM processing_log ORDER BY seq DESC LIMIT 1;
  NEW.seq        := COALESCE(last_seq, 0) + 1;
  NEW.prev_hash  := COALESCE(last_hash, repeat('0', 64));
  NEW.created_at := now();
  NEW.hash       := NULL;
  NEW.hash       := log_chain_hash(NEW.prev_hash, to_jsonb(NEW) - 'hash' - 'prev_hash');
  RETURN NEW;
END $$;

CREATE FUNCTION log_reject_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'processing_log is append-only: % is not allowed', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER processing_log_append BEFORE INSERT ON processing_log
  FOR EACH ROW EXECUTE FUNCTION log_chain_append();
CREATE TRIGGER processing_log_no_update BEFORE UPDATE OR DELETE ON processing_log
  FOR EACH ROW EXECUTE FUNCTION log_reject_change();
CREATE TRIGGER processing_log_no_truncate BEFORE TRUNCATE ON processing_log
  FOR EACH STATEMENT EXECUTE FUNCTION log_reject_change();

-- Recompute the whole chain; returns the first broken row (or nothing if intact).
CREATE FUNCTION processing_log_verify()
RETURNS TABLE(bad_seq bigint, reason text)
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE r record; expect_prev text := repeat('0', 64); expect_seq bigint := 1; h text;
BEGIN
  FOR r IN SELECT * FROM processing_log ORDER BY seq LOOP
    IF r.seq <> expect_seq THEN bad_seq := r.seq; reason := 'gap in seq'; RETURN NEXT; RETURN; END IF;
    IF r.prev_hash <> expect_prev THEN bad_seq := r.seq; reason := 'prev_hash mismatch'; RETURN NEXT; RETURN; END IF;
    h := log_chain_hash(r.prev_hash, to_jsonb(r) - 'hash' - 'prev_hash');
    IF h <> r.hash THEN bad_seq := r.seq; reason := 'hash mismatch (row altered)'; RETURN NEXT; RETURN; END IF;
    expect_prev := r.hash; expect_seq := r.seq + 1;
  END LOOP;
END $$;

-- ------------------------------------------------------------ app permissions
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO pipe_app;
GRANT SELECT, INSERT, UPDATE ON documents, line_items TO pipe_app;
GRANT DELETE ON line_items TO pipe_app;          -- needed when a reviewer fixes the items
GRANT SELECT, INSERT ON processing_log TO pipe_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO pipe_app;
GRANT EXECUTE ON FUNCTION processing_log_verify() TO pipe_app;
