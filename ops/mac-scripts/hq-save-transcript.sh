#!/usr/bin/env bash
# hq-save-transcript.sh <session-id> <suffix>
# Copies this Claude Code session's transcript to Ragnarok HQ's transcripts/
# on Alexus, checks the copy is byte-exact, prints ARCHIVE_PATH and SHA256 for
# the Session_Transcripts row. Used by /save and /end (ported from Gemini 10-31).
set -euo pipefail
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"
SID="${1:?session id}"; SUFFIX="${2:-$(date -u +%Y%m%d-%H%M%S)}"
SRC=$(ls "$HOME"/.claude/projects/*/"$SID".jsonl 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "SAVE FAILED: no transcript for $SID"; exit 1; }
SHA=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
DEST="/home/${OWNER}/Developer/ragnarok-hq/transcripts/claude-code-$SID-$SUFFIX.jsonl"
SSH=(/usr/bin/ssh -i "$HOME/.ssh/id_claude" -o BatchMode=yes -o IdentitiesOnly=yes)
/usr/bin/scp -q -i "$HOME/.ssh/id_claude" -o BatchMode=yes -o IdentitiesOnly=yes "$SRC" "claude@alexus:$DEST" \
  || { echo "SAVE FAILED: copy to Alexus failed"; exit 1; }
RSHA=$("${SSH[@]}" claude@alexus "sha256sum '$DEST'" | cut -d' ' -f1)
[ "$RSHA" = "$SHA" ] || { echo "SAVE FAILED: sha mismatch (local $SHA, Alexus $RSHA)"; exit 1; }
echo "ARCHIVE_PATH=$DEST"
echo "SHA256=$SHA"
echo "BYTES=$(wc -c < "$SRC" | tr -d ' ')"
