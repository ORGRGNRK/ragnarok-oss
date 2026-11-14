#!/bin/bash
# Sends photos dropped in ~/Receipts-Inbox to Alexus (~/receipts-inbox there, which the pipe picks up every minute),
# then moves each sent file to ~/Receipts-Inbox/sent/. Never deletes anything. Run by launchd (co.rgnrk.receipts-inbox-sync).
IN="$HOME/Receipts-Inbox"; SENT="$IN/sent"; HOST=alexus
LOG="$HOME/Library/Logs/receipts-inbox-sync.log"
mkdir -p "$SENT"
LOCK="$IN/.sync.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0   # another run is busy
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0         # stale lock from a crash
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
now=$(date +%s); files=(); sigs=()
for f in "$IN"/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in .*|*.part|*.tmp|*.crdownload|*.download|*.icloud) continue;; esac
  m=$(stat -f %m "$f"); [ $((now - m)) -ge 10 ] || continue            # too new: may still be copying
  files+=("$f"); sigs+=("$(stat -f '%z %m' "$f")")
done
[ ${#files[@]} -gt 0 ] || exit 0
sleep 3
for i in "${!files[@]}"; do
  f="${files[$i]}"; name=$(basename "$f")
  [ -f "$f" ] && [ "$(stat -f '%z %m' "$f")" = "${sigs[$i]}" ] || continue   # still changing: next run
  safe=$(printf %s "$name" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  dest="mac-$(date +%Y%m%d-%H%M%S)-$i-$safe"
  # write under a hidden name, then rename, so the Alexus side never sees a half-copied file
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "mkdir -p receipts-inbox && cat > receipts-inbox/.up-$dest && mv receipts-inbox/.up-$dest receipts-inbox/$dest" < "$f"; then
    target="$SENT/$name"; [ -e "$target" ] && target="$SENT/$(date +%Y%m%d-%H%M%S)-$name"
    mv "$f" "$target"
    echo "$(date '+%F %T') sent $name (as $dest)" >> "$LOG"
  else
    echo "$(date '+%F %T') couldn't reach Alexus for $name; it stays in Receipts-Inbox and will be retried" >> "$LOG"
    break
  fi
done
