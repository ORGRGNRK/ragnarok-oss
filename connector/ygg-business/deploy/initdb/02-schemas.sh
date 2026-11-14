#!/bin/sh
# First boot only. Creates the generic schema and MCP schema on app_db,
# owned by app_owner, then grants app_read / ygg_read read access.
#   /ygg-sql/platform/*.sql -> app_db.public (items, leads, channels, items_with_totals)
#   /ygg-sql/mcp/*.sql      -> app_db.mcp    (receipts, search_vectors, index_state, auth_state)
set -e

apply() { # $1 = database, $2 = dir
  for f in "$2"/*.sql; do
    [ -e "$f" ] || continue
    { echo "set role app_owner;"; cat "$f"; } | psql -v ON_ERROR_STOP=1 -q -U postgres -d "$1" -f -
    echo "02-schemas: applied $(basename "$f") to $1"
  done
}

apply app_db /ygg-sql/platform
apply app_db /ygg-sql/mcp

psql -v ON_ERROR_STOP=1 -q -U postgres -d app_db <<'SQL'
grant usage on schema public to app_read, ygg_read;
grant select on all tables in schema public to app_read, ygg_read;
grant select on all sequences in schema public to app_read, ygg_read;
alter default privileges for role app_owner in schema public grant select on tables to app_read, ygg_read;
alter default privileges for role app_owner in schema public grant select on sequences to app_read, ygg_read;

-- Event Triggers to audit any DDL actions (DROP TABLE, CREATE TABLE, ALTER TABLE) into mcp.receipts
create or replace function mcp.log_drop_receipt() returns event_trigger
language plpgsql security definer set search_path = mcp, public as $$
declare
  r record;
begin
  for r in select * from pg_event_trigger_dropped_objects() loop
    if r.schema_name not in ('pg_toast', 'pg_temp', 'information_schema') and r.object_type = 'table' then
      insert into mcp.receipts (tool_name, payload, status)
      values (
        'postgres_drop_table',
        jsonb_build_object(
          'action', 'DROP TABLE',
          'schema', r.schema_name,
          'table', r.object_name,
          'identity', r.object_identity,
          'actor', session_user,
          'source', 'nocodb_or_direct_sql'
        ),
        'verified'
      );
    end if;
  end loop;
end;
$$;

drop event trigger if exists trg_audit_drop_table;
create event trigger trg_audit_drop_table
on sql_drop
execute function mcp.log_drop_receipt();

create or replace function mcp.log_ddl_receipt() returns event_trigger
language plpgsql security definer set search_path = mcp, public as $$
declare
  r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.schema_name not in ('pg_toast', 'pg_temp', 'information_schema') and r.object_type = 'table' then
      insert into mcp.receipts (tool_name, payload, status)
      values (
        'postgres_' || lower(replace(r.command_tag, ' ', '_')),
        jsonb_build_object(
          'action', r.command_tag,
          'schema', r.schema_name,
          'identity', r.object_identity,
          'actor', session_user,
          'source', 'nocodb_or_direct_sql'
        ),
        'verified'
      );
    end if;
  end loop;
end;
$$;

drop event trigger if exists trg_audit_ddl_table;
create event trigger trg_audit_ddl_table
on ddl_command_end
execute function mcp.log_ddl_receipt();
SQL

echo "02-schemas: grants for read-only roles completed"
