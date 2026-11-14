#!/bin/sh
# First boot only (empty data dir).
# Generic roles:
#   - app_owner: database owner, runs migrations and manages schema mcp
#   - app_read: read-only role used for all analytical and MCP reading
#   - nocodb: owns metadata for NocoDB
set -e

OWNER_PW="${APP_OWNER_PASSWORD:-${YGG_APP_PASSWORD}}"
READ_PW="${APP_READ_PASSWORD:-${YGG_READ_PASSWORD}}"
META_PW="${NC_META_PASSWORD}"

psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres <<SQL
create role app_owner login password '${OWNER_PW}';
create role app_read login password '${READ_PW}';
create role nocodb login password '${META_PW}';

-- Aliases for backward compatibility if configured
do \$\$
begin
  if not exists (select from pg_roles where rolname = 'ygg_app') then
    create role ygg_app with login password '${OWNER_PW}';
  end if;
  if not exists (select from pg_roles where rolname = 'ygg_read') then
    create role ygg_read with login password '${READ_PW}';
  end if;
end
\$\$;

create database app_db owner app_owner;
create database nocodb_meta owner nocodb;

revoke connect on database app_db, nocodb_meta from public;
grant connect on database app_db to app_read, ygg_read;
grant connect on database app_db to ygg_app;
SQL

echo "01-roles: generic roles (app_owner, app_read, nocodb) and databases initialized"
