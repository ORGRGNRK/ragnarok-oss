#!/usr/bin/env bash
# Hardware Presence Platform Lock
# Immediately seals/locks the Docker MCP platform.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\033[1;34m[lock]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[lock] 🔒 %s\033[0m\n' "$*"; }

HTTP_PORT="${PLATFORM_MCP_HTTP_PORT:-${YGG_MCP_HTTP_PORT:-8787}}"
if [ -e .env ]; then
  P_PORT=$(sed -n 's/^PLATFORM_MCP_HTTP_PORT=//p' .env | tail -1)
  [ -n "$P_PORT" ] && HTTP_PORT="$P_PORT"
fi

if curl -s -f "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then
  curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/lock" \
    -H "Content-Type: application/json" \
    -d "{}" >/dev/null
  ok "Docker MCP platform is now SEALED / LOCKED. Hardware presence required to unseal."
else
  say "Container not running on port ${HTTP_PORT}."
fi
