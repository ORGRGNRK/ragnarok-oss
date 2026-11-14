-- MCP-owned state for this project database. Idempotent; touches schema mcp only.
-- Applied as the database owner role (app_owner) by `npm run migrate`.

create schema if not exists mcp;
create extension if not exists pgcrypto;

-- Cryptographic linear hash chain functions for mcp.receipts
create or replace function mcp.receipt_chain_hash(prev_hash text, content jsonb) returns text
language sql immutable set search_path = public, mcp as $$
  select encode(digest(prev_hash || E'\n' || content::text, 'sha256'), 'hex')
$$;

create or replace function mcp.receipt_chain_append() returns trigger
language plpgsql set timezone = 'UTC' set search_path = public, mcp as $$
declare last_seq bigint; last_hash text;
begin
  perform pg_advisory_xact_lock(hashtext('mcp_receipt_chain'), hashtext(TG_TABLE_NAME));
  execute format('select seq, hash from %I.%I order by seq desc limit 1', TG_TABLE_SCHEMA, TG_TABLE_NAME) into last_seq, last_hash;
  NEW.seq        := coalesce(last_seq, 0) + 1;
  NEW.prev_hash  := coalesce(last_hash, repeat('0', 64));
  NEW.hash       := mcp.receipt_chain_hash(NEW.prev_hash, to_jsonb(NEW) - 'seq' - 'prev_hash' - 'hash');
  return NEW;
end;
$$;

-- Cryptographically chained receipt ledger
create table if not exists mcp.receipts (
  seq           bigint primary key,
  tool_name     text        not null,
  payload       jsonb       not null default '{}'::jsonb,
  status        text        not null default 'verified',
  created_at    timestamptz not null default now(),
  prev_hash     text        not null,
  hash          text        not null unique
);

create index if not exists receipts_tool_seq_idx on mcp.receipts (tool_name, seq desc);
create index if not exists receipts_created_seq_idx on mcp.receipts (created_at desc, seq desc);

drop trigger if exists mcp_receipts_chain on mcp.receipts;
create trigger mcp_receipts_chain
  before insert on mcp.receipts
  for each row execute function mcp.receipt_chain_append();

-- Recompute the whole chain. ok=false names the first bad seq.
create or replace function mcp.verify()
returns table (ok boolean, checked bigint, first_bad_seq bigint, reason text) language plpgsql stable as $$
declare
  r record; v_prev text := repeat('0', 64); v_n bigint := 0; v_expect bigint := 1;
begin
  for r in select * from mcp.receipts order by seq loop
    v_n := v_n + 1;
    if r.seq <> v_expect then return query select false, v_n, r.seq, 'gap in seq'; return; end if;
    if r.prev_hash <> v_prev then return query select false, v_n, r.seq, 'prev_hash does not match previous entry'; return; end if;
    if mcp.receipt_chain_hash(r.prev_hash, to_jsonb(r) - 'seq' - 'prev_hash' - 'hash') <> r.hash then
      return query select false, v_n, r.seq, 'hash does not match payload'; return;
    end if;
    v_prev := r.hash; v_expect := v_expect + 1;
  end loop;
  return query select true, v_n, null::bigint, 'chain intact'::text;
end $$;

grant usage on schema mcp to app_read, ygg_read;
grant select on mcp.receipts to app_read, ygg_read;
grant execute on function mcp.verify() to app_read, ygg_read;

-- Search vectors.
create table if not exists mcp.search_vectors (
  item_id      bigint      not null,
  model        text        not null,
  embedding    real[]      not null,
  content_hash text        not null,
  updated_at   timestamp   not null,
  indexed_at   timestamptz not null default now(),
  primary key (item_id, model)
);

-- Incremental indexing position per embedding model
create table if not exists mcp.index_state (
  model           text        primary key,
  last_updated_at timestamp   not null,
  last_id         bigint      not null,
  synced_at       timestamptz not null default now()
);

-- Hardware presence authentication sessions / audit ledger
create table if not exists mcp.auth_state (
  id            bigserial primary key,
  method        text        not null,
  status        text        not null,
  session_token text,
  unlocked_at   timestamptz not null default now(),
  expires_at    timestamptz
);
