#!/bin/bash
# Creates .env (web app) and db.env (Postgres container) with fresh random passwords, mode 600.
# Refuses to overwrite existing files. Never prints the values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
umask 077
[ -e .env ] || [ -e db.env ] && { echo ".env or db.env already exists; not touching them"; exit 1; }
gen() { python3 -c 'import secrets;print(secrets.token_urlsafe(24))'; }
ADMIN_PW=$(gen); APP_PW=$(gen); WEB_PW=$(gen)
cat > db.env <<E
POSTGRES_USER=pipe_admin
POSTGRES_DB=pipe
POSTGRES_PASSWORD=$ADMIN_PW
PIPE_APP_DB_PASSWORD=$APP_PW
E
cat > .env <<E
# Web login for the upload page (HTTP basic auth)
PIPE_WEB_USER=chris
PIPE_WEB_PASSWORD=$WEB_PW
# Database (app role pipe_app; it cannot change or delete the processing log)
DATABASE_URL=postgresql://pipe_app:$APP_PW@127.0.0.1:5544/pipe
# Admin DB login (only for maintenance, not used by the app)
PIPE_ADMIN_DATABASE_URL=postgresql://pipe_admin:$ADMIN_PW@127.0.0.1:5544/pipe
OLLAMA_URL=http://127.0.0.1:11434
PIPE_MODEL=qwen2.5vl:3b
PIPE_MAX_SIDE=1280
PIPE_IMAGE_DIR=$ROOT/data/images
E
chmod 600 .env db.env
echo "wrote .env and db.env (mode 600)"
