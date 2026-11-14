#!/bin/sh
# Runs once, the first time the database volume is created.
# Creates the low-privilege role the web app uses. Password comes from db.env (never stored here).
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v app_pw="$PIPE_APP_DB_PASSWORD" <<'EOSQL'
CREATE ROLE pipe_app LOGIN PASSWORD :'app_pw';
EOSQL
