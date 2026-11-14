#!/bin/bash
# Run on Alexus as the owner:  sudo bash ~/Developer/ragnarok/ops/alexus/claude-code/install.sh
# Puts the owner's hooks in root-owned managed settings for every Claude Code on Alexus. With allowManagedHooksOnly,
# hooks in a user's own ~/.claude/settings.json are ignored, so an AI account can't remove or replace these.
# The scripts they run are read-only for the AI accounts (ragnarok-ai group), set 2026-11-08.
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)/managed-settings.json"
# The template says @OWNER_HOME@; it becomes the home of whoever owns this checkout.
OWNER_HOME=$(getent passwd "$(stat -c %U "$(cd "$(dirname "$0")/../../.." && pwd)")" | cut -d: -f6)
[ -n "$OWNER_HOME" ] || { echo "could not find the owner's home" >&2; exit 1; }
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
sed "s|@OWNER_HOME@|$OWNER_HOME|g" "$SRC" > "$TMP"
python3 -m json.tool "$TMP" >/dev/null
install -d -o root -g root -m 755 /etc/claude-code
install -o root -g root -m 644 "$TMP" /etc/claude-code/managed-settings.json
ls -l /etc/claude-code/managed-settings.json
echo "installed. In Claude Code on Alexus, /status should list managed settings under Setting sources."
