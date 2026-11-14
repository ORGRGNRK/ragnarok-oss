#!/bin/bash
# new-instance.sh NAME APP_PORT DB_PORT — a second, separate copy of the pipe on its own ports (run on Alexus as the
# user that runs the main pipe). Same code and model; its OWN database (Docker container ragnarok-pipe-NAME-db on
# 127.0.0.1:DB_PORT, volume ragnarok-pipe-NAME-pgdata), its own photo folder and its own login, so nothing mixes with
# the main pipe. The web app listens on 0.0.0.0:APP_PORT (home network, basic-auth login like the main one).
#
#   files:  <checkout>/instances/NAME/{.env,db.env,docker-compose.yml,data/images}   (secrets mode 600, never committed)
#   unit:   ~/.config/systemd/user/ragnarok-pipe-NAME-app.service
#
# The web password comes from $WEB_PW if set (the Mac's bin/ragnarok-pipe-money-setup sends it, after saving it in the
# Mac keychain), otherwise a random one is made. Nothing secret is printed. Refuses to touch an existing instance or a
# port that is already in use. Example:  deploy/new-instance.sh money 8449 5545
set -euo pipefail
NAME="${1:-}"; APP_PORT="${2:-}"; DB_PORT="${3:-}"
ROOT="${PIPE_ROOT:-$HOME/Developer/ragnarok-pipe}"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{0,20}$ ]] || { echo "usage: new-instance.sh NAME APP_PORT DB_PORT (NAME: lowercase letters/digits/-)"; exit 2; }
[[ "$APP_PORT" =~ ^[0-9]{4,5}$ && "$DB_PORT" =~ ^[0-9]{4,5}$ ]] || { echo "ports must be numbers"; exit 2; }
[ -x "$ROOT/.venv/bin/uvicorn" ] || { echo "no pipe checkout with a .venv at $ROOT"; exit 1; }
DIR="$ROOT/instances/$NAME"
UNIT="ragnarok-pipe-$NAME-app.service"
[ -e "$DIR" ] && { echo "instance $NAME already exists at $DIR; not touching it"; exit 1; }
[ -e "$HOME/.config/systemd/user/$UNIT" ] && { echo "$UNIT already exists; not touching it"; exit 1; }
for p in "$APP_PORT" "$DB_PORT"; do
  ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && { echo "port $p is already in use"; exit 1; }
done
command -v docker >/dev/null || { echo "docker isn't installed"; exit 1; }

# a setup that fails partway moves its own half-made folder aside (never deleted), so running it again works
DONE=0
on_exit() { [ "$DONE" = 1 ] && return; [ -d "$DIR" ] || return
  docker compose -f "$DIR/docker-compose.yml" down >/dev/null 2>&1 || true   # stops the container; the volume is kept
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  [ -e "$HOME/.config/systemd/user/$UNIT" ] && mv "$HOME/.config/systemd/user/$UNIT" "$DIR/$UNIT"
  mv "$DIR" "$DIR.failed-$(date +%Y%m%d-%H%M%S)"; echo "setup failed; the half-made instance was moved to $DIR.failed-*"; }
trap on_exit EXIT
docker compose version >/dev/null 2>&1 || { echo "docker compose isn't available"; exit 1; }

umask 077
mkdir -p "$DIR/data/images"
gen() { python3 -c 'import secrets;print(secrets.token_urlsafe(24))'; }
ADMIN_PW="$(gen)"; APP_PW="$(gen)"; WEB_PW="${WEB_PW:-$(gen)}"; WEB_USER="${WEB_USER:-ragnarok}"
cat > "$DIR/db.env" <<E
POSTGRES_USER=pipe_admin
POSTGRES_DB=pipe
POSTGRES_PASSWORD=$ADMIN_PW
PIPE_APP_DB_PASSWORD=$APP_PW
E
cat > "$DIR/.env" <<E
# Instance "$NAME" of ragnarok-pipe (made by deploy/new-instance.sh)
PIPE_WEB_USER=$WEB_USER
PIPE_WEB_PASSWORD=$WEB_PW
DATABASE_URL=postgresql://pipe_app:$APP_PW@127.0.0.1:$DB_PORT/pipe
PIPE_ADMIN_DATABASE_URL=postgresql://pipe_admin:$ADMIN_PW@127.0.0.1:$DB_PORT/pipe
OLLAMA_URL=http://127.0.0.1:11434
PIPE_MODEL=qwen2.5vl:3b
PIPE_MAX_SIDE=1280
PIPE_IMAGE_DIR=$DIR/data/images
E
cat > "$DIR/docker-compose.yml" <<E
name: ragnarok-pipe-$NAME
services:
  db:
    image: postgres:16-alpine
    container_name: ragnarok-pipe-$NAME-db
    restart: always
    env_file: [./db.env]
    ports: ["127.0.0.1:$DB_PORT:5432"]
    volumes:
      - ragnarok-pipe-$NAME-pgdata:/var/lib/postgresql/data
      - $ROOT/db/init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pipe_admin -d pipe"]
      interval: 5s
      timeout: 3s
      retries: 20
volumes:
  ragnarok-pipe-$NAME-pgdata:
E
chmod 600 "$DIR/.env" "$DIR/db.env"
umask 022

echo "starting the $NAME database on 127.0.0.1:$DB_PORT"
docker compose -f "$DIR/docker-compose.yml" up -d >/dev/null
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "ragnarok-pipe-$NAME-db" 2>/dev/null)" = healthy ] && break
  sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "ragnarok-pipe-$NAME-db")" = healthy ] || { echo "the database didn't become healthy"; exit 1; }

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/$UNIT" <<E
[Unit]
Description=Ragnarok pipe ($NAME instance) on port $APP_PORT
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
EnvironmentFile=$DIR/.env
ExecStart=$ROOT/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port $APP_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
E
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT" >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf -m 2 "http://127.0.0.1:$APP_PORT/healthz" >/dev/null && break; sleep 1; done
if out=$(curl -sf -m 3 "http://127.0.0.1:$APP_PORT/healthz"); then
  DONE=1; echo "instance $NAME is up on port $APP_PORT: $out (login user: $WEB_USER)"
else
  echo "the app didn't answer on port $APP_PORT; see: journalctl --user -u $UNIT -n 50"; exit 1
fi
