-- Mac receipts: one hash-chained, append-only log of every command / file write an AI makes on
-- the owner's MacBook. Lives in the scratch database ygg_receipts, schema "mac" (the per-machine log).
-- It never touches the restored public tables ("Write Log", "Archive") or any business table.
-- Idempotent. Applied as ygg_app by `node hooks/mac-receipts/receipt.mjs migrate`.

create schema if not exists mac;

create table if not exists mac.receipts (
  seq          bigint      primary key,                 -- chain position, 1..n, no gaps
  rid          uuid        not null unique,             -- client id; a re-sent spool line is ignored
  at           timestamptz not null,                    -- when the command / write happened (client clock)
  logged_at    timestamptz not null default clock_timestamp(),
  host         text        not null,
  kind         text        not null check (kind in ('Read','Change')),
  action       text        not null check (action in ('Read','Created','Updated','Deleted')),
  status       text        not null check (status in ('Observed','Failed')),
  exit_code    integer,
  actor        text        not null,
  session      text,
  source       text,                                    -- which hook wrote it (zsh-exit, claude-posttooluse, ...)
  tool         text,
  record_ref   text        not null,                    -- host:clean path, or host:cwd
  cwd          text,
  command      text,                                    -- redacted command text, or "write (contents not logged)"
  payload      jsonb       not null,                    -- everything above, exactly as hashed
  prev_hash    text        not null,
  entry_hash   text        not null unique
);
create index if not exists mac_receipts_at_idx on mac.receipts (at desc);
create index if not exists mac_receipts_actor_idx on mac.receipts (actor, seq desc);

-- Append-only: no UPDATE / DELETE / TRUNCATE, for anyone (owner included, short of dropping the trigger).
create or replace function mac.refuse_change() returns trigger language plpgsql as $$
begin
  raise exception 'mac.receipts is append-only (% refused)', tg_op;
end $$;
drop trigger if exists receipts_no_update_delete on mac.receipts;
create trigger receipts_no_update_delete before update or delete on mac.receipts
  for each row execute function mac.refuse_change();
drop trigger if exists receipts_no_truncate on mac.receipts;
create trigger receipts_no_truncate before truncate on mac.receipts
  for each statement execute function mac.refuse_change();

-- entry_hash = sha256(prev_hash || "\n" || payload::text). Genesis prev_hash = 64 zeros.
create or replace function mac.entry_hash(prev text, p jsonb) returns text language sql immutable as $$
  select encode(sha256(convert_to(prev || E'\n' || p::text, 'UTF8')), 'hex')
$$;

-- The only write path. Serialised with an advisory lock so the chain never forks.
create or replace function mac.append(p jsonb)
returns table (seq bigint, entry_hash text, inserted boolean) language plpgsql as $$
declare
  v_prev text; v_seq bigint; v_hash text; v_rid uuid := (p->>'rid')::uuid;
begin
  perform pg_advisory_xact_lock(hashtext('mac.receipts'));
  select r.seq, r.entry_hash into v_seq, v_hash from mac.receipts r where r.rid = v_rid;
  if found then
    return query select v_seq, v_hash, false; return;
  end if;
  select r.seq, r.entry_hash into v_seq, v_prev from mac.receipts r order by r.seq desc limit 1;
  v_seq := coalesce(v_seq, 0) + 1;
  v_prev := coalesce(v_prev, repeat('0', 64));
  v_hash := mac.entry_hash(v_prev, p);
  insert into mac.receipts (seq, rid, at, host, kind, action, status, exit_code, actor, session, source, tool,
                            record_ref, cwd, command, payload, prev_hash, entry_hash)
  values (v_seq, v_rid, (p->>'at')::timestamptz, p->>'host', p->>'kind', p->>'action', p->>'status',
          (p->>'exit_code')::integer, p->>'actor', p->>'session', p->>'source', p->>'tool',
          p->>'record_ref', p->>'cwd', p->>'command', p, v_prev, v_hash);
  return query select v_seq, v_hash, true;
end $$;

-- Recompute the whole chain. ok=false names the first bad seq.
create or replace function mac.verify()
returns table (ok boolean, checked bigint, first_bad_seq bigint, reason text) language plpgsql stable as $$
declare
  r record; v_prev text := repeat('0', 64); v_n bigint := 0; v_expect bigint := 1;
begin
  for r in select * from mac.receipts order by seq loop
    v_n := v_n + 1;
    if r.seq <> v_expect then return query select false, v_n, r.seq, 'gap in seq'; return; end if;
    if r.prev_hash <> v_prev then return query select false, v_n, r.seq, 'prev_hash does not match previous entry'; return; end if;
    if mac.entry_hash(r.prev_hash, r.payload) <> r.entry_hash then
      return query select false, v_n, r.seq, 'entry_hash does not match payload'; return;
    end if;
    if r.command is distinct from r.payload->>'command' or r.record_ref is distinct from r.payload->>'record_ref'
       or r.status is distinct from r.payload->>'status' or r.actor is distinct from r.payload->>'actor' then
      return query select false, v_n, r.seq, 'column differs from hashed payload'; return;
    end if;
    v_prev := r.entry_hash; v_expect := v_expect + 1;
  end loop;
  return query select true, v_n, null::bigint, 'chain intact'::text;
end $$;

grant usage on schema mac to ygg_read;
grant select on mac.receipts to ygg_read;
grant execute on function mac.verify() to ygg_read;
