-- 01_kit.sql: the parts every client gets, no matter what their tables look like.
-- Runs ONCE, on the first start of an empty database, as the admin login.
--
--   write_log   one row per change to any client table, archive or approval (old -> new).
--               Written by a database trigger, so it happens no matter who made the change
--               (the AI, NocoDB, psql).
--   access_log  one row per AI tool call (who asked, what, did it work, which receipt).
--   archive     soft-deleted records. Nothing is ever hard-deleted by the AI.
--   approvals   one-time codes a human approves in a terminal before an archive can happen.
--   kit_tables  which tables belong to the client (filled from client/schema.json).
--
-- write_log and access_log are append-only and hash-chained INSIDE the database:
--   seq        1, 2, 3 ... with no gaps
--   prev_hash  the previous row's hash (64 zeros for the first row)
--   hash       sha256(prev_hash + newline + the row's content as JSON)
-- Triggers refuse UPDATE, DELETE and TRUNCATE on them for everyone, the admin included, and no
-- app login is even granted INSERT on write_log. kit_verify() recomputes every hash and also
-- checks that the lock triggers are still switched on.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE kit_tables (
  sql_name     text PRIMARY KEY,
  display_name text NOT NULL UNIQUE
);

CREATE TABLE write_log (
  seq         bigint PRIMARY KEY,
  receipt_id  text NOT NULL UNIQUE DEFAULT ('rec_' || replace(gen_random_uuid()::text, '-', '')),
  action      text NOT NULL,             -- INSERT / UPDATE / DELETE
  table_name  text NOT NULL,
  record_id   text,
  old_value   jsonb,
  new_value   jsonb,
  actor       text NOT NULL,
  session     text,
  note        text,                       -- the "why", if the caller gave one
  created_at  timestamptz NOT NULL DEFAULT now(),
  prev_hash   text NOT NULL,
  hash        text NOT NULL UNIQUE
);
CREATE INDEX write_log_record ON write_log (table_name, record_id, seq);

CREATE TABLE access_log (
  seq         bigint PRIMARY KEY,
  event_uid   text NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
  tool        text NOT NULL,
  ok          boolean NOT NULL,
  scope       text NOT NULL,             -- read / write
  actor       text NOT NULL,             -- what the AI said it is
  via         text NOT NULL,             -- what the server saw: stdio:user@host or http:<token name>
  session     text,
  detail      jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  prev_hash   text NOT NULL,
  hash        text NOT NULL UNIQUE
);

CREATE TABLE archive (
  id             bigserial PRIMARY KEY,
  source_table   text NOT NULL,
  source_id      bigint NOT NULL,
  record         jsonb NOT NULL,
  reason         text NOT NULL,
  actor          text NOT NULL,
  approval_code  text NOT NULL,
  archived_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE approvals (
  code          text PRIMARY KEY,
  action        text NOT NULL DEFAULT 'archive',
  table_name    text NOT NULL,
  record_id     bigint NOT NULL,
  reason        text NOT NULL,
  requested_by  text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  approved_at   timestamptz,
  approved_by   text,
  used_at       timestamptz
);

-- ------------------------------------------------------------------ hash chain

CREATE FUNCTION receipt_chain_hash(prev_hash text, content jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT encode(digest(prev_hash || E'\n' || content::text, 'sha256'), 'hex')
$$;

-- timezone pinned to UTC so timestamps always serialize the same way when hashed.
CREATE FUNCTION receipt_chain_append() RETURNS trigger
LANGUAGE plpgsql SET timezone = 'UTC' SET search_path = public AS $$
DECLARE last_seq bigint; last_hash text;
BEGIN
  -- one writer at a time per log; held until the transaction ends, so the chain can't fork
  PERFORM pg_advisory_xact_lock(hashtext('kit_receipt_chain'), hashtext(TG_TABLE_NAME));
  EXECUTE format('SELECT seq, hash FROM %I ORDER BY seq DESC LIMIT 1', TG_TABLE_NAME) INTO last_seq, last_hash;
  NEW.seq        := COALESCE(last_seq, 0) + 1;
  NEW.prev_hash  := COALESCE(last_hash, repeat('0', 64));
  NEW.created_at := now();              -- the database's clock, never the caller's
  NEW.hash       := NULL;
  NEW.hash       := receipt_chain_hash(NEW.prev_hash, to_jsonb(NEW) - 'hash' - 'prev_hash');
  RETURN NEW;
END $$;

CREATE FUNCTION receipt_reject_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'receipts are append-only: % on % is not allowed', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'insufficient_privilege';
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['write_log', 'access_log'] LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_chain BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION receipt_chain_append()', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_no_change BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION receipt_reject_change()', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_no_truncate BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION receipt_reject_change()', t, t);
  END LOOP;
END $$;

-- kit_verify() (recomputes every chain + checks the locks) is created by `./kit up` (mcp/src/agentlog.ts),
-- so existing clients get new chains too.

-- ------------------------------------------------- automatic receipts for data changes
-- Attached to every client table (by ./kit up), plus archive and approvals.
-- Who did it: SET LOCAL receipt.actor / receipt.session / receipt.note in the same transaction (the MCP
-- server does this); otherwise the database login name is recorded.
CREATE FUNCTION kit_write_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o jsonb; n jsonb;
BEGIN
  IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN n := to_jsonb(NEW); END IF;
  INSERT INTO write_log (action, table_name, record_id, old_value, new_value, actor, session, note)
  VALUES (TG_OP, TG_TABLE_NAME,
          COALESCE(COALESCE(n, o)->>'id', COALESCE(n, o)->>'code'),
          o, n,
          COALESCE(NULLIF(current_setting('receipt.actor', true), ''), session_user),
          NULLIF(current_setting('receipt.session', true), ''),
          NULLIF(current_setting('receipt.note', true), ''));
  RETURN NULL;
END $$;

CREATE TRIGGER trg_archive_write_log AFTER INSERT OR UPDATE OR DELETE ON archive
  FOR EACH ROW EXECUTE FUNCTION kit_write_log();
CREATE TRIGGER trg_approvals_write_log AFTER INSERT OR UPDATE OR DELETE ON approvals
  FOR EACH ROW EXECUTE FUNCTION kit_write_log();

-- keeps updated_at honest on client tables
CREATE FUNCTION kit_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ---------------------------------------------- soft delete with a human approval code
-- 1. The AI asks:      kit_request_archive(table, id, reason, actor)  -> code (e.g. ARC-7F3K9Q2M)
-- 2. A human approves: kit_approve(code, who)   (admin login only: ./kit approve CODE)
-- 3. The AI finishes:  kit_archive(table, id, code, reason, actor)
--    copies the whole record into archive, removes it from the table, burns the code.
-- The AI's login has no DELETE privilege on any table; this function is the only way.

CREATE FUNCTION kit_check_table(p_table text) RETURNS void
LANGUAGE plpgsql STABLE SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM kit_tables WHERE sql_name = p_table) THEN
    RAISE EXCEPTION 'unknown table %', p_table USING ERRCODE = 'invalid_parameter_value';
  END IF;
END $$;

CREATE FUNCTION kit_request_archive(p_table text, p_id bigint, p_reason text, p_actor text, p_ttl_hours int DEFAULT 24)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c text; found boolean;
BEGIN
  PERFORM kit_check_table(p_table);
  IF coalesce(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'a reason is required'; END IF;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE id = $1)', p_table) INTO found USING p_id;
  IF NOT found THEN RAISE EXCEPTION 'no record % in %', p_id, p_table USING ERRCODE = 'no_data_found'; END IF;
  c := 'ARC-' || upper(substr(translate(encode(gen_random_bytes(12), 'base64'), '+/=0O1Il', ''), 1, 8));
  INSERT INTO approvals (code, table_name, record_id, reason, requested_by, expires_at)
  VALUES (c, p_table, p_id, p_reason, p_actor, now() + make_interval(hours => greatest(1, least(p_ttl_hours, 168))));
  RETURN c;
END $$;

CREATE FUNCTION kit_approve(p_code text, p_by text DEFAULT session_user)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a approvals;
BEGIN
  SELECT * INTO a FROM approvals WHERE code = upper(trim(p_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'no approval request with code %', p_code; END IF;
  IF a.used_at IS NOT NULL THEN RAISE EXCEPTION 'code % was already used', a.code; END IF;
  IF a.expires_at < now() THEN RAISE EXCEPTION 'code % expired at %', a.code, a.expires_at; END IF;
  IF a.approved_at IS NOT NULL THEN RETURN format('%s was already approved', a.code); END IF;
  PERFORM set_config('receipt.actor', 'approver: ' || p_by, true);
  UPDATE approvals SET approved_at = now(), approved_by = p_by WHERE code = a.code;
  RETURN format('approved %s: archive %s #%s (%s)', a.code, a.table_name, a.record_id, a.reason);
END $$;

CREATE FUNCTION kit_archive(p_table text, p_id bigint, p_code text, p_reason text, p_actor text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a approvals; rec jsonb; aid bigint;
BEGIN
  PERFORM kit_check_table(p_table);
  SELECT * INTO a FROM approvals WHERE code = upper(trim(p_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approval code % does not exist', p_code USING ERRCODE = 'insufficient_privilege'; END IF;
  IF a.table_name <> p_table OR a.record_id <> p_id THEN
    RAISE EXCEPTION 'approval code % is for % #%, not % #%', a.code, a.table_name, a.record_id, p_table, p_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF a.used_at IS NOT NULL THEN RAISE EXCEPTION 'approval code % was already used', a.code USING ERRCODE = 'insufficient_privilege'; END IF;
  IF a.expires_at < now() THEN RAISE EXCEPTION 'approval code % expired', a.code USING ERRCODE = 'insufficient_privilege'; END IF;
  IF a.approved_at IS NULL THEN
    RAISE EXCEPTION 'approval code % has not been approved yet. A person must run: ./kit approve %', a.code, a.code USING ERRCODE = 'insufficient_privilege';
  END IF;
  EXECUTE format('SELECT to_jsonb(t) FROM %I t WHERE id = $1 FOR UPDATE', p_table) INTO rec USING p_id;
  IF rec IS NULL THEN RAISE EXCEPTION 'no record % in %', p_id, p_table USING ERRCODE = 'no_data_found'; END IF;
  INSERT INTO archive (source_table, source_id, record, reason, actor, approval_code)
  VALUES (p_table, p_id, rec, coalesce(nullif(trim(p_reason), ''), a.reason), p_actor, a.code) RETURNING id INTO aid;
  EXECUTE format('DELETE FROM %I WHERE id = $1', p_table) USING p_id;
  UPDATE approvals SET used_at = now() WHERE code = a.code;
  RETURN aid;
END $$;

-- Nobody gets these by default; ./kit up grants the right ones to the right login.
REVOKE ALL ON FUNCTION kit_request_archive(text, bigint, text, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION kit_approve(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION kit_archive(text, bigint, text, text, text) FROM PUBLIC;
