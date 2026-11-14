-- receipts_v2.sql: access_log learns which MODEL was behind a tool call. Applied by every
-- `./kit up` / `./kit test` (apply_schema), after db/init/01_kit.sql. Safe to re-run.
--
-- New nullable access_log columns:
--   receipt_v       NULL = a row written before this file (receipt format 1); 2 = every row since.
--   model_reported  the model name as the model API itself reported it in its response, when the
--                   server made the model call (e.g. the brain tools' embedding call to Ollama).
--                   NULL when no model call was made by the server, so for any outside MCP client.
--   model_claimed   the model name the CLIENT says it is (optional `model_claimed` argument).
--                   Self-reported, never checked; like `actor`, it is a claim, not evidence.
--
-- The hash chain stays valid for old rows. A row's hashed content is
--   receipt_chain_content(to_jsonb(row) - 'hash' - 'prev_hash'):
--     format 1 (receipt_v NULL): the three new keys are left out -> exactly the JSON that was
--       hashed when the row was written, so every old row still verifies, unchanged;
--     format 2 (receipt_v = 2): the whole row, the new keys included (also when NULL), so a
--       model name on a new row is covered by its hash and cannot be added or edited later.
-- The insert trigger stamps receipt_v = 2 on every new access_log row, whatever the caller sent,
-- and kit_verify() also reports a format-1 row that carries a model name (not covered by a hash).

ALTER TABLE access_log ADD COLUMN IF NOT EXISTS receipt_v      smallint;
ALTER TABLE access_log ADD COLUMN IF NOT EXISTS model_reported text;
ALTER TABLE access_log ADD COLUMN IF NOT EXISTS model_claimed  text;

CREATE OR REPLACE FUNCTION receipt_chain_content(content jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE WHEN content ? 'receipt_v' AND jsonb_typeof(content -> 'receipt_v') <> 'null' THEN content
              ELSE content - 'receipt_v' - 'model_reported' - 'model_claimed' END
$$;

CREATE OR REPLACE FUNCTION receipt_chain_append() RETURNS trigger
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE last_seq bigint; last_hash text;
BEGIN
  -- one writer at a time per log; held until the transaction ends, so the chain can't fork
  PERFORM pg_advisory_xact_lock(hashtext('kit_receipt_chain'), hashtext(TG_TABLE_NAME));
  EXECUTE format('SELECT seq, hash FROM %I ORDER BY seq DESC LIMIT 1', TG_TABLE_NAME) INTO last_seq, last_hash;
  NEW.seq        := COALESCE(last_seq, 0) + 1;
  NEW.prev_hash  := COALESCE(last_hash, repeat('0', 64));
  NEW.created_at := now();              -- the database's clock, never the caller's
  -- receipt format 2 on logs that have the column (access_log); ignored where it doesn't exist
  IF to_jsonb(NEW) ? 'receipt_v' THEN
    NEW := jsonb_populate_record(NEW, '{"receipt_v": 2}'::jsonb);
  END IF;
  NEW.hash       := NULL;
  NEW.hash       := receipt_chain_hash(NEW.prev_hash, receipt_chain_content(to_jsonb(NEW) - 'hash' - 'prev_hash'));
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION kit_verify()
RETURNS TABLE(chain text, rows_checked bigint, intact boolean, first_bad_seq bigint, problem text,
              head_hash text, lock_on boolean, lock_problem text)
LANGUAGE plpgsql STABLE SET timezone = 'UTC' SET search_path = public AS $$
DECLARE t text; r record; exp_prev text; exp_seq bigint; n bigint; bad bigint; prob text; locks int;
BEGIN
  FOREACH t IN ARRAY ARRAY['write_log', 'access_log'] LOOP
    exp_prev := repeat('0', 64); exp_seq := 1; n := 0; bad := NULL; prob := NULL;
    FOR r IN EXECUTE format('SELECT x.seq, x.prev_hash, x.hash, to_jsonb(x) - ''hash'' - ''prev_hash'' AS content FROM %I x ORDER BY x.seq', t) LOOP
      n := n + 1;
      IF r.seq IS DISTINCT FROM exp_seq THEN
        bad := r.seq; prob := format('sequence gap: expected #%s, found #%s (a row was removed)', exp_seq, r.seq); EXIT;
      END IF;
      IF r.prev_hash IS DISTINCT FROM exp_prev THEN
        bad := r.seq; prob := 'prev_hash does not match the row before it'; EXIT;
      END IF;
      IF r.hash IS DISTINCT FROM receipt_chain_hash(r.prev_hash, receipt_chain_content(r.content)) THEN
        bad := r.seq; prob := 'row content does not match its hash (the row was edited)'; EXIT;
      END IF;
      IF jsonb_typeof(r.content -> 'receipt_v') IS DISTINCT FROM 'number'
         AND (coalesce(jsonb_typeof(r.content -> 'model_reported'), 'null') <> 'null'
              OR coalesce(jsonb_typeof(r.content -> 'model_claimed'), 'null') <> 'null') THEN
        bad := r.seq; prob := 'an old-format row carries a model name its hash does not cover (the row was edited)'; EXIT;
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
END $$;

REVOKE ALL ON FUNCTION kit_verify() FROM PUBLIC;
