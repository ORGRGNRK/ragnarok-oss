#!/bin/sh
# Build the Touch ID helper and print the Claude Code hook snippet.
# This script does not edit ~/.claude/settings.json.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PY="$ROOT/touchgate.py"
chmod +x "$PY" "$ROOT/make.sh" || true

echo "TouchGate"
echo ""
built=0
if [ "$(uname -s)" = "Darwin" ]; then
  if "$ROOT/make.sh"; then
    built=1
  else
    echo "The Touch ID helper did not build. The hook will fail closed until it does." >&2
  fi
else
  echo "This machine is not macOS. The Touch ID helper was not built."
  echo "Linux support is planned. Until then the hook fails closed and blocks destructive commands."
fi

cat <<EOF

Paste this into Claude Code settings yourself.
install.sh does not edit ~/.claude/settings.json.

{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|mcp__.*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 $PY",
            "timeout": 120
          }
        ]
      }
    ]
  }
}

Cursor and Codex are not supported yet. They do not run this Claude Code hook.
If the helper is missing, or this is not a Mac, TouchGate denies the command.
EOF

if [ "$(uname -s)" = "Darwin" ] && [ "$built" -ne 1 ]; then
  exit 1
fi
