# shellcheck shell=bash
# Shared helpers for ./kit, ./new-client.sh and scripts/test.sh. Works with macOS bash 3.2.
# Source it; don't run it.
#   COMPOSE         compose command (default "docker compose")
#   KIT_ENV_FILE    which settings file to use (default: .env in the kit folder)
#   KIT_CLIENT_DIR  the client's schema.json + seed.json (default: client/ in the kit folder)
#   One kit serves every client: ragnarok/clients/<name>/kit sets both to that client's folder.

# Apps like Claude Desktop start us with a bare PATH; make sure docker (OrbStack/Docker Desktop/Homebrew) is found
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:/Applications/Docker.app/Contents/Resources/bin"
export PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE:-docker compose}"
KIT_ENV_FILE="${KIT_ENV_FILE:-$ROOT/.env}"
KIT_CLIENT_DIR="${KIT_CLIENT_DIR:-$ROOT/client}"
[ -d "$KIT_CLIENT_DIR" ] || KIT_CLIENT_DIR="$ROOT/examples/inventory"   # the kit on its own (./kit test): the example tables
KIT_HOME="$(dirname "$KIT_ENV_FILE")"   # the client's own folder: its .env, backups/
export KIT_CLIENT_DIR                   # docker-compose.yml mounts it into the MCP container

say()  { printf '%s\n' "$*"; }
bold() { if [ -t 1 ]; then printf '\033[1m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# random hex string of 2*N characters
rand() { openssl rand -hex "$1" 2>/dev/null || od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

# make_env SOURCE DEST PROJECT_NAME : copy SOURCE, replacing every =CHANGE-ME with a fresh secret
make_env() {
  local src="$1" dest="$2" proj="$3" line key
  ( umask 077
    : > "$dest"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        COMPOSE_PROJECT_NAME=*) printf 'COMPOSE_PROJECT_NAME=%s\n' "$proj" ;;
        *=CHANGE-ME)
          key="${line%%=*}"
          case "$key" in
            MCP_TOKEN|MCP_READ_TOKEN|RECEIPT_TOKEN) printf '%s=%s\n' "$key" "$(rand 32)" ;;
            *) printf '%s=%s\n' "$key" "$(rand 24)" ;;
          esac ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$src" >> "$dest" )
  chmod 600 "$dest"
}

load_env() {
  [ -f "$KIT_ENV_FILE" ] || die "no settings file at $KIT_ENV_FILE (run ./kit up once, or ./new-client.sh)"
  if grep -v '^[[:space:]]*#' "$KIT_ENV_FILE" | grep -q 'CHANGE-ME'; then
    die "$KIT_ENV_FILE still has CHANGE-ME placeholders; replace them (names only shown): $(grep '^[^#]*CHANGE-ME' "$KIT_ENV_FILE" | cut -d= -f1 | tr '\n' ' ')"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$KIT_ENV_FILE"
  set +a
  write_secrets
}

# write_secrets: .env stays the one place secrets are kept; the containers get them as files (Docker secrets)
# so they never show up in `docker inspect`. Folder 0700 = only this user on the host; files 0644 so the
# container's own user (postgres, node) can read the mounted file.
write_secrets() {
  KIT_SECRETS_DIR="$KIT_HOME/.secrets"; export KIT_SECRETS_DIR
  ( umask 077; mkdir -p "$KIT_SECRETS_DIR" ); chmod 700 "$KIT_SECRETS_DIR"
  local pair name var
  for pair in pg_admin_password:POSTGRES_PASSWORD mcp_db_password:MCP_DB_PASSWORD mcp_ro_db_password:MCP_RO_DB_PASSWORD \
              ui_db_password:UI_DB_PASSWORD mcp_token:MCP_TOKEN mcp_read_token:MCP_READ_TOKEN receipt_token:RECEIPT_TOKEN nc_jwt_secret:NC_AUTH_JWT_SECRET; do
    name="${pair%%:*}"; var="${pair#*:}"
    ( umask 022; eval "printf '%s' \"\${$var:-}\"" > "$KIT_SECRETS_DIR/$name.tmp" ) && mv "$KIT_SECRETS_DIR/$name.tmp" "$KIT_SECRETS_DIR/$name"
  done
}

dc() {
  # A client may add compose.yaml (Intake does, for its file directory). Other clients have none.
  local files=(-f "$ROOT/docker-compose.yml")
  if [ -f "$KIT_HOME/compose.yaml" ]; then files+=(-f "$KIT_HOME/compose.yaml"); fi
  (cd "$ROOT" && $COMPOSE "${files[@]}" --env-file "$KIT_ENV_FILE" -p "${COMPOSE_PROJECT_NAME:?}" "$@")
}

# admin_psql [psql args]: psql as the admin login, inside the postgres container
admin_psql() { dc exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 "$@"; }

wait_pg() {
  local i=0
  while [ $i -lt 60 ]; do
    dc exec -T postgres pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && return 0
    i=$((i+1)); sleep 2
  done
  die "Postgres did not become ready (see: ./kit logs postgres)"
}

wait_mcp() {
  local i=0 port
  while [ $i -lt 60 ]; do
    port="$(dc port mcp 8787 2>/dev/null | head -1 | sed 's/.*://')"
    if [ -n "$port" ] && curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      MCP_HOST_PORT="$port"; return 0
    fi
    i=$((i+1)); sleep 2
  done
  die "MCP server did not become healthy (see: ./kit logs mcp)"
}

# run the kit helper (schema check / SQL generation) inside the MCP image
kit_cli() {
  local err rc=0
  err="$(mktemp)"
  dc run --rm --no-deps -T mcp node dist/src/cli.js "$@" 2>"$err" || rc=$?
  # compose prints "Container ... Created" chatter on stderr; show stderr only if something failed
  [ $rc -eq 0 ] || grep -v -e ' Container ' "$err" >&2 || true
  rm -f "$err"; return $rc
}

apply_schema() {
  kit_cli check >/dev/null || die "client/schema.json or client/seed.json has a problem (see above)"
  kit_cli schema-sql | admin_psql -q >/dev/null || die "could not apply client/schema.json to the database"
}
