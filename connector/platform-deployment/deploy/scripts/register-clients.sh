#!/bin/sh
# Register the packaged MCP with Claude Code and print a JSON snippet for Claude Desktop / other
# MCP clients. No secrets: the client runs `docker compose exec`, which reads .env itself.
#   register-clients.sh [--name NAME] [--http] [--print-only] [--dry-run]
#     --name NAME    server name (default ygg-business-docker). Refuses a name that already exists,
#                    so an existing registration (e.g. ygg-business) is never touched.
#     --http         register the Streamable HTTP URL instead of stdio
#     --print-only   only print the JSON snippets
#     --dry-run      print the `claude mcp add` command instead of running it
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd -P)
NAME=ygg-business-docker; HTTP=0; PRINT=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --name) NAME=$2; shift;; --http) HTTP=1;; --print-only) PRINT=1;; --dry-run) DRY=1;;
  *) echo "unknown option $1"; exit 2;; esac; shift; done
DOCKER=$(command -v docker) || { echo "docker not found"; exit 2; }
DOCKER_DIR=$(dirname "$DOCKER")
case ":/usr/local/bin:/usr/bin:/bin:" in *":$DOCKER_DIR:"*) CPATH=/usr/local/bin:/usr/bin:/bin;; *) CPATH=$DOCKER_DIR:/usr/local/bin:/usr/bin:/bin;; esac
PORT=$(sed -n 's/^PLATFORM_MCP_HTTP_PORT=//p' .env | tail -1)
[ -z "$PORT" ] && PORT=$(sed -n 's/^YGG_MCP_HTTP_PORT=//p' .env | tail -1)
[ -z "$PORT" ] && PORT=8787

if [ "$PRINT" = 0 ]; then
  if command -v claude >/dev/null 2>&1; then
    if claude mcp get "$NAME" >/dev/null 2>&1; then
      echo "register: Claude Code already has server $NAME registered (reusing existing registration)"
    else
      if [ "$HTTP" = 1 ]; then
        set -- claude mcp add --scope user --transport http "$NAME" "http://127.0.0.1:$PORT/mcp"
      else
        set -- claude mcp add --scope user --transport stdio "$NAME" --env "PATH=$CPATH" \
          -- "$DOCKER" compose --project-directory "$ROOT" exec -T mcp node dist/index.js
      fi
      if [ "$DRY" = 1 ]; then echo "would run: $*"; else "$@" && claude mcp get "$NAME"; fi
    fi
  else
    echo "register: claude CLI not found; skipping Claude Code (use the JSON below)"
  fi
fi

cat <<JSON
--- Claude Desktop (claude_desktop_config.json -> mcpServers) / any stdio MCP client ---
{
  "mcpServers": {
    "$NAME": {
      "command": "$DOCKER",
      "args": ["compose", "--project-directory", "$ROOT", "exec", "-T", "mcp", "node", "dist/index.js"],
      "env": { "PATH": "$CPATH" }
    }
  }
}
--- Streamable HTTP clients (localhost only, no auth) ---
{ "mcpServers": { "$NAME-http": { "type": "http", "url": "http://127.0.0.1:$PORT/mcp" } } }
JSON
