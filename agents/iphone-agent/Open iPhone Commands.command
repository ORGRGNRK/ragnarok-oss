#!/bin/zsh

set -e
LAUNCHER_ROOT="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_URL="http://127.0.0.1:4177"

if /usr/bin/curl --silent --fail "$LAUNCHER_URL/api/bootstrap" >/dev/null 2>&1; then
  /usr/bin/open "$LAUNCHER_URL"
  exit 0
fi

LAUNCHER_NODE="$(command -v node 2>/dev/null || true)"

# Apps opened from Finder don't get the shell PATH, so also look where Homebrew installs node.
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [[ -z "$LAUNCHER_NODE" && -x "$candidate" ]] && LAUNCHER_NODE="$candidate"
done

if [[ -z "$LAUNCHER_NODE" ]]; then
  /usr/bin/osascript -e 'display alert "iPhone Commands needs Node.js" message "Install Node.js (brew install node), then open this again." as critical'
  exit 1
fi

exec "$LAUNCHER_NODE" "$LAUNCHER_ROOT/dist/launcher-server.js"
