#!/usr/bin/env bash
# One-command install of the packaged Business MCP stack:
#   ./install.sh                 # gen .env (if missing) -> build -> up -d -> wait healthy -> verify
#   ./install.sh --with-search   # also start Ollama + pull nomic-embed-text (large download)
#   ./install.sh --check         # prerequisites only
# Inputs (env, non-secret): COMPOSE_PROJECT_NAME, YGG_PG_PORT, YGG_NC_PORT, YGG_MCP_HTTP_PORT,
# NC_ADMIN_EMAIL, YGG_MCP_TAG (see deploy/scripts/gen-env.sh). Never prints a secret.
set -euo pipefail
cd "$(dirname "$0")"
WITH_SEARCH=0; CHECK_ONLY=0
for a in "$@"; do case "$a" in
  --with-search) WITH_SEARCH=1;; --check) CHECK_ONLY=1;;
  -h|--help) sed -n 2,8p "$0"; exit 0;; *) echo "unknown option $a"; exit 2;; esac; done

say() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
envval() { sed -n "s/^$1=//p" .env | tail -1; }   # non-secret keys only
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak
  else
    echo "${key}=${val}" >> .env
  fi
  chmod 600 .env
}

find_free_port() {
  local min="${1:-8788}" max="${2:-8999}"
  node -e "
    import net from 'node:net';
    const min = $min, max = $max;
    const ports = Array.from({length: max - min + 1}, (_, i) => min + i).sort(() => Math.random() - 0.5);
    async function find() {
      for (const p of ports) {
        const ok = await new Promise(r => {
          const s = net.createServer();
          s.listen(p, '127.0.0.1', () => s.close(() => r(true))).on('error', () => r(false));
        });
        if (ok) { console.log(p); return; }
      }
      console.log(min);
    }
    find();
  " 2>/dev/null || echo "$min"
}

# 1. prerequisites
command -v docker >/dev/null || die "docker not found (install Docker Desktop, OrbStack or Docker Engine)"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (start Docker Desktop / OrbStack)"
command -v openssl >/dev/null || die "openssl not found"
say "prerequisites ok: $(docker compose version --short 2>/dev/null || docker compose version)"
[ "$CHECK_ONLY" = 1 ] && exit 0

# 2. secrets
if [ -e .env ]; then
  say ".env exists; reusing it (secrets unchanged)"
else
  PLATFORM_ENABLE_SEARCH=$WITH_SEARCH deploy/scripts/gen-env.sh
fi
[ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = 600 ] || chmod 600 .env
if [ "$WITH_SEARCH" = 1 ] && [ "$(envval COMPOSE_PROFILES)" != search ]; then
  sed -i.bak 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=search/' .env && rm -f .env.bak && chmod 600 .env
  say "enabled profile search in .env"
fi
PROJECT=$(envval COMPOSE_PROJECT_NAME)
FRESH=0; [ -z "$(docker volume ls -q --filter "name=^${PROJECT}_pgdata\$")" ] && FRESH=1
say "compose project: $PROJECT ($([ $FRESH = 1 ] && echo "fresh install: new empty database" || echo "existing database volume: data kept"))"

# 2.1 compile host Apple Secure Enclave Touch ID helper if swiftc is present
if [ -x deploy/auth/build-auth.sh ]; then
  deploy/auth/build-auth.sh >/dev/null 2>&1 || true
fi

# 3. dynamic ports (allocates a fresh, free port on every run to prevent conflicts)
NEW_MCP_PORT=$(find_free_port 8788 8999)
set_env PLATFORM_MCP_HTTP_PORT "$NEW_MCP_PORT"
say "MCP HTTP assigned to fresh dynamic port: 127.0.0.1:$NEW_MCP_PORT"

# Ensure NocoDB port is free; if busy by another project, pick a new free port
NC_P=$(envval PLATFORM_NC_PORT)
[ -z "$NC_P" ] && NC_P=$(envval YGG_NC_PORT)
[ -z "$NC_P" ] && NC_P=8095
if [ -z "$(docker compose ps -q nocodb 2>/dev/null)" ] && port_busy "$NC_P"; then
  NEW_NC_PORT=$(find_free_port 8096 8199)
  set_env PLATFORM_NC_PORT "$NEW_NC_PORT"
  say "NocoDB port $NC_P was busy; remapped to dynamic port 127.0.0.1:$NEW_NC_PORT"
fi

# Ensure Postgres port is free; if busy by another project, pick a new free port
PG_P=$(envval PLATFORM_PG_PORT)
[ -z "$PG_P" ] && PG_P=$(envval YGG_PG_PORT)
[ -z "$PG_P" ] && PG_P=5557
if [ -z "$(docker compose ps -q pg 2>/dev/null)" ] && port_busy "$PG_P"; then
  NEW_PG_PORT=$(find_free_port 5558 5699)
  set_env PLATFORM_PG_PORT "$NEW_PG_PORT"
  say "PostgreSQL port $PG_P was busy; remapped to dynamic port 127.0.0.1:$NEW_PG_PORT"
fi

# 4. build + start
docker compose config -q
say "building image and starting containers (first run pulls ~2 GB of images)"
docker compose up -d --build --remove-orphans
say "waiting for pg, nocodb, mcp to be healthy/running"
docker compose up -d --wait --wait-timeout 300 pg nocodb mcp >/dev/null

# 5. install receipt (one per install run) + verification
deploy/scripts/receipts.sh append installer "install.sh $([ $FRESH = 1 ] && echo fresh || echo re-run) project=$PROJECT" >/dev/null
deploy/scripts/verify.sh --quick

# 6. automated NocoDB base & source configuration, demo data, MCP client registration, and vector indexing
if [ -x deploy/scripts/auto-setup.mjs ] || [ -f deploy/scripts/auto-setup.mjs ]; then
  [ -d node_modules ] || npm ci --silent
  say "running automated platform setup (NocoDB, demo data, client registration, semantic vector index)..."
  node deploy/scripts/auto-setup.mjs
fi

say "done. Stack is RUNNING and BOOT-LOCKED by default."
say "      Unlock with: ./unlock.sh (YubiKey physical touch or Apple Touch ID)"
say "      Lock with:   ./lock.sh"
say "      MCP stdio:   docker compose exec -T mcp node dist/index.js"
say "      MCP HTTP:    http://127.0.0.1:$(envval PLATFORM_MCP_HTTP_PORT || envval YGG_MCP_HTTP_PORT)/mcp"
say "      NocoDB:      http://127.0.0.1:$(envval PLATFORM_NC_PORT || envval YGG_NC_PORT)"
