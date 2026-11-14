#!/bin/sh
# Writes ./.env with fresh random secrets (chmod 600). Refuses to overwrite. Prints no secret values.
# Non-secret inputs come from the environment (defaults in brackets):
#   COMPOSE_PROJECT_NAME [secure-mcp-platform]  PLATFORM_PG_PORT [5557]  PLATFORM_NC_PORT [8095]  PLATFORM_MCP_HTTP_PORT [8787]
#   NC_ADMIN_EMAIL [admin@example.local]   PLATFORM_ENABLE_SEARCH [0] (1 -> COMPOSE_PROFILES=search)
#   PLATFORM_MCP_TAG [local]  (image tag secure-mcp-platform:<tag>)
set -eu
cd "$(dirname "$0")/../.."
[ -e .env ] && { echo "gen-env: .env exists; not overwriting (delete it only if you also remove the volumes)"; exit 1; }
command -v openssl >/dev/null || { echo "gen-env: openssl not found"; exit 2; }
find_free_port() {
  node -e "
    import net from 'node:net';
    const min = $1, max = $2;
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
  " 2>/dev/null || echo "$1"
}

PROJECT=${COMPOSE_PROJECT_NAME:-secure-mcp-platform}
PG=${PLATFORM_PG_PORT:-${YGG_PG_PORT:-5557}}
NC=${PLATFORM_NC_PORT:-${YGG_NC_PORT:-8095}}
HTTP=${PLATFORM_MCP_HTTP_PORT:-${YGG_MCP_HTTP_PORT:-}}
[ -z "$HTTP" ] && HTTP=$(find_free_port 8788 8999)
EMAIL=${NC_ADMIN_EMAIL:-admin@example.local}
TAG=${PLATFORM_MCP_TAG:-${YGG_MCP_TAG:-local}}
case "$PROJECT" in *[!a-z0-9_-]*|"") echo "gen-env: COMPOSE_PROJECT_NAME must be lowercase letters, digits, - or _"; exit 2;; esac
for p in "$PG" "$NC" "$HTTP"; do case "$p" in *[!0-9]*|"") echo "gen-env: ports must be numbers"; exit 2;; esac; done
PROFILES=; [ "${PLATFORM_ENABLE_SEARCH:-${YGG_ENABLE_SEARCH:-0}}" = 1 ] && PROFILES=search
umask 077
h() { openssl rand -hex "$1"; }
OWNER_PW=$(h 24)
READ_PW=$(h 24)
# Use an explicit remote endpoint or the optional Compose Ollama service.
EMBEDDER_URL=${PLATFORM_EMBEDDER_URL:-${BUSINESS_EMBEDDER_URL:-http://ollama:11434}}
EMBEDDER_MODEL=${PLATFORM_EMBEDDER_MODEL:-${BUSINESS_EMBEDDER_MODEL:-nomic-embed-text}}

{
echo "# secure-mcp-platform secrets, generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Never print, paste or commit."
echo "COMPOSE_PROJECT_NAME=$PROJECT"
echo "COMPOSE_PROFILES=$PROFILES"
echo "PLATFORM_MCP_TAG=$TAG"
echo "PLATFORM_PG_PORT=$PG"
echo "PLATFORM_NC_PORT=$NC"
echo "PLATFORM_MCP_HTTP_PORT=$HTTP"
echo "POSTGRES_PASSWORD=$(h 24)"
echo "APP_OWNER_PASSWORD=$OWNER_PW"
echo "APP_READ_PASSWORD=$READ_PW"
echo "YGG_APP_PASSWORD=$OWNER_PW"
echo "YGG_READ_PASSWORD=$READ_PW"
echo "NC_META_PASSWORD=$(h 24)"
echo "NC_AUTH_JWT_SECRET=$(h 32)"
echo "NC_ADMIN_EMAIL=$EMAIL"
echo "NC_ADMIN_PASSWORD=Ys$(h 14)#9"
echo "PLATFORM_REQUIRE_AUTH=true"
echo "PLATFORM_SESSION_TTL_MINUTES=60"
echo "PLATFORM_UNLOCK_SECRET=$(h 32)"
echo "PLATFORM_EMBEDDER_URL=$EMBEDDER_URL"
echo "PLATFORM_EMBEDDER_MODEL=$EMBEDDER_MODEL"
} > .env
chmod 600 .env
echo "gen-env: wrote .env (600): project=$PROJECT pg=127.0.0.1:$PG nocodb=127.0.0.1:$NC mcp-http=127.0.0.1:$HTTP profiles=${PROFILES:-none}"
