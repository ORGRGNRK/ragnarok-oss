#!/bin/sh
# Remove this install's containers. Data volumes are KEPT unless --delete-data is given AND
# YGG_CONFIRM_DELETE=<project name> is set (deleting volumes destroys the database: human decision).
#   ./uninstall.sh                                   stop + remove containers, keep volumes and .env
#   YGG_CONFIRM_DELETE=<project> ./uninstall.sh --delete-data   also remove volumes, image and .env
set -eu
cd "$(dirname "$0")"
[ -e .env ] || { echo "uninstall: no .env here; nothing to do"; exit 0; }
P=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -1)
[ -n "$P" ] || { echo "uninstall: COMPOSE_PROJECT_NAME missing in .env"; exit 2; }
if [ "${1:-}" = --delete-data ]; then
  [ "${PLATFORM_CONFIRM_DELETE:-${YGG_CONFIRM_DELETE:-}}" = "$P" ] || { echo "uninstall: set PLATFORM_CONFIRM_DELETE=$P to delete project $P's volumes"; exit 1; }
  if [ -x "./unlock.sh" ]; then
    echo "🔐 DESTRUCTIVE ACTION: Requiring hardware presence authorization..."
    ./unlock.sh || { echo "uninstall: hardware authorization refused. Data kept intact."; exit 1; }
  fi
  docker compose -p "$P" --profile search down -v --remove-orphans
  T=$(sed -n 's/^PLATFORM_MCP_TAG=//p' .env 2>/dev/null || sed -n 's/^YGG_MCP_TAG=//p' .env | tail -1); docker image rm "secure-mcp-platform:${T:-local}" 2>/dev/null || true
  rm -f .env
  echo "uninstall: project $P removed with its volumes, image and .env"
else
  docker compose -p "$P" --profile search down --remove-orphans
  echo "uninstall: project $P containers removed; volumes and .env kept (./install.sh brings it back)"
fi
