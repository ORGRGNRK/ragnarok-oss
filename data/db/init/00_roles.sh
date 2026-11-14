#!/bin/sh
# 00_roles.sh: runs ONCE, the first time Postgres starts with an empty data volume.
# Creates the low-privilege logins (passwords come from .env) and NocoDB's own settings
# database (owned by the ui login). What each login may touch is decided in the grants that `./kit up` applies.
#   mcp_rw : the AI's tools in normal (read + write) mode. Read, add, update. No delete.
#   mcp_ro : the AI's tools in read-only mode. Read only (+ it may add access-log rows).
#   ui     : what NocoDB logs in as. Read, add, update. No delete, can't touch receipts.
set -eu
: "${MCP_DB_USER:?}"; : "${MCP_DB_PASSWORD:?}"
: "${MCP_RO_DB_USER:?}"; : "${MCP_RO_DB_PASSWORD:?}"
: "${UI_DB_USER:?}"; : "${UI_DB_PASSWORD:?}"
: "${NOCODB_META_DB:=nocodb_meta}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v rw_user="$MCP_DB_USER" -v rw_pw="$MCP_DB_PASSWORD" \
     -v ro_user="$MCP_RO_DB_USER" -v ro_pw="$MCP_RO_DB_PASSWORD" \
     -v ui_user="$UI_DB_USER" -v ui_pw="$UI_DB_PASSWORD" \
     -v meta_db="$NOCODB_META_DB" -v app_db="$POSTGRES_DB" <<'SQL'
CREATE ROLE :"rw_user" LOGIN PASSWORD :'rw_pw';
CREATE ROLE :"ro_user" LOGIN PASSWORD :'ro_pw';
CREATE ROLE :"ui_user" LOGIN PASSWORD :'ui_pw';
-- NocoDB keeps its own settings in a separate database it owns, so NocoDB never needs the admin password.
CREATE DATABASE :"meta_db" OWNER :"ui_user";
REVOKE ALL ON DATABASE :"app_db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"app_db" TO :"rw_user", :"ro_user", :"ui_user";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"rw_user", :"ro_user", :"ui_user";
SQL
