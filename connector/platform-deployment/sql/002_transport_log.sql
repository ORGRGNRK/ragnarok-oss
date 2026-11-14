-- Transport audit log for HTTP / network requests.
-- Each incoming request is sealed with duration, client IP, method, status, and token.
-- Sequenced and hashed via receipt_chain_append().

create extension if not exists pgcrypto;

create or replace function receipt_chain_hash(prev_hash text, content jsonb) returns text
language sql immutable set search_path = public as $$
  select encode(digest(prev_hash || E'\n' || content::text, 'sha256'), 'hex')
$$;

create or replace function receipt_chain_append() returns trigger
language plpgsql set timezone = 'UTC' set search_path = public as $$
declare last_seq bigint; last_hash text;
begin
  perform pg_advisory_xact_lock(hashtext('kit_receipt_chain'), hashtext(TG_TABLE_NAME));
  execute format('select seq, hash from %I order by seq desc limit 1', TG_TABLE_NAME) into last_seq, last_hash;
  NEW.seq        := coalesce(last_seq, 0) + 1;
  NEW.prev_hash  := coalesce(last_hash, repeat('0', 64));
  NEW.hash       := receipt_chain_hash(NEW.prev_hash, to_jsonb(NEW) - 'seq' - 'prev_hash' - 'hash');
  return NEW;
end;
$$;

create table if not exists transport_log (
  seq           bigint primary key,
  client_ip     text not null,
  method        text not null,
  path          text not null,
  status_code   integer not null,
  token_label   text,
  duration_ms   real not null,
  error_message text,
  created_at    timestamptz not null default now(),
  prev_hash     text not null,
  hash          text not null unique
);

create index if not exists transport_log_status_seq on transport_log (status_code, seq desc);
create index if not exists transport_log_created_seq on transport_log (created_at desc, seq desc);

drop trigger if exists transport_log_chain on transport_log;
create trigger transport_log_chain
  before insert on transport_log
  for each row execute function receipt_chain_append();

grant select, insert on transport_log to public;
