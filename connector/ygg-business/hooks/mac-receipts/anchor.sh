#!/usr/bin/env bash
# anchor.sh -- runs on the MAC every hour (launchd co.rgnrk.mac-receipts.anchor). Two jobs for the
# live AI receipt chain (ygg-scratch-pg / ygg_receipts / mac.receipts on Alexus):
#
#   1. Scheduled check: runs mac.verify() over the whole chain, every hour, not only when someone looks.
#   2. Off-server anchor: keeps the newest (seq, entry_hash) here on the Mac, in an append-only file
#      inside a local git repo. Next run asks the server for the hash it NOW holds at that seq. Because
#      every hash covers all the receipts before it, a matching hash proves nothing up to that point was
#      changed -- even by someone with the Postgres admin login who turned off the trigger and recomputed
#      every hash (mac.verify() alone cannot catch that).
#
# Good  -> appends the server's line to $DIR/$NAME.jsonl and commits.
# Bad   -> leaves $NAME.jsonl alone (later runs keep comparing against the last GOOD anchor and keep
#          alerting), writes evidence to $NAME.rejected.jsonl + $NAME.alerts.log, macOS notification, exit 2.
# Exit: 0 ok, 2 ALERT (broken or rewritten), 3 could not reach/read the server (not a tamper sign).
#
# Same design as data/scripts/mac-anchor.sh (that one is for the data/ kit's write_log/access_log).
# Env: ANCHOR_SSH_TARGET (alexus)  ANCHOR_DIR (~/RAGNAROK-anchors)  ANCHOR_NAME (mac-receipts)
#      ANCHOR_NOTIFY (1)  ANCHOR_APPEND_ONLY (1)  ANCHOR_SSH (ssh; tests swap in a fake)
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

TARGET="${ANCHOR_SSH_TARGET:-alexus}"
DIR="${ANCHOR_DIR:-$HOME/RAGNAROK-anchors}"
NAME="${ANCHOR_NAME:-mac-receipts}"
SSH_BIN="${ANCHOR_SSH:-ssh}"
NOTIFY="${ANCHOR_NOTIFY:-1}"
APPEND_ONLY="${ANCHOR_APPEND_ONLY:-1}"
FILE="$DIR/$NAME.jsonl"; REJ="$DIR/$NAME.rejected.jsonl"; ALERTS="$DIR/$NAME.alerts.log"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fail3() { echo "[anchor $(now)] $NAME: $*" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || fail3 "jq is needed"

mkdir -p "$DIR" || fail3 "cannot create $DIR"
lock="$DIR/.$NAME.lock"
mkdir "$lock" 2>/dev/null || fail3 "another run is in progress (remove $lock if stale)"
trap 'rmdir "$lock" 2>/dev/null' EXIT
[ -d "$DIR/.git" ] || { git -C "$DIR" init -q && printf '.*.lock/\n' > "$DIR/.gitignore"; } || fail3 "git init failed"
for f in "$FILE" "$REJ" "$ALERTS"; do
  if [ ! -e "$f" ]; then : > "$f"; [ "$APPEND_ONLY" = 1 ] && chflags uappnd "$f" 2>/dev/null; fi
done
commit() {
  git -C "$DIR" add -A >/dev/null 2>&1
  git -C "$DIR" -c user.name="RAGNAROK anchor" -c user.email="anchor@localhost" commit -q -m "$1" >/dev/null 2>&1 \
    || git -C "$DIR" diff --cached --quiet || echo "[anchor] warning: git commit failed in $DIR" >&2
}

# ---- last good anchor
prev="$(grep -v '^[[:space:]]*$' "$FILE" | tail -1)"
ps=0; ph=""
if [ -n "$prev" ]; then
  echo "$prev" | jq -e . >/dev/null 2>&1 || fail3 "last line of $FILE is not valid JSON; fix by hand"
  ps="$(echo "$prev" | jq -r '.seq')"; ph="$(echo "$prev" | jq -r '.head')"
fi
case "$ps" in ''|*[!0-9]*) fail3 "bad seq in last anchor: $ps" ;; esac

# ---- ask the server (read-only login ygg_read). One JSON line.
sql="select json_build_object('v',1,'at',to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
 'intact',v.ok,'checked',v.checked,'first_bad_seq',v.first_bad_seq,'reason',v.reason,
 'seq',(select max(seq) from mac.receipts),
 'head',(select entry_hash from mac.receipts order by seq desc limit 1),
 'trigger_on',(select count(*)=2 from pg_trigger where tgrelid='mac.receipts'::regclass and tgenabled<>'D' and not tgisinternal),
 'check_seq',$ps,'check_hash',(select entry_hash from mac.receipts where seq=$ps)) from mac.verify() v"
line="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
  "docker exec ygg-scratch-pg psql -U ygg_read -d ygg_receipts -Atc $(printf '%q' "$sql")" 2>"$DIR/.$NAME.ssh-err")"; rc=$?
line="$(printf '%s\n' "$line" | grep '^{' | tail -1)"
if [ -z "$line" ] || ! echo "$line" | jq -e '.v == 1' >/dev/null 2>&1; then
  err="$(tail -3 "$DIR/.$NAME.ssh-err" 2>/dev/null | tr '\n' ' ')"; rm -f "$DIR/.$NAME.ssh-err"
  fail3 "could not read the chain from $TARGET (exit $rc): ${err:-no output}"
fi
rm -f "$DIR/.$NAME.ssh-err"
line="$(echo "$line" | jq -c .)"

# ---- compare
problems=()
j() { echo "$line" | jq -r "$1"; }
[ "$(j .intact)" = true ] || problems+=("chain check FAILED at receipt #$(j .first_bad_seq): $(j .reason)")
[ "$(j .trigger_on)" = true ] || problems+=("the append-only trigger on mac.receipts is OFF or missing")
if [ -n "$prev" ]; then
  cs="$(j .seq)"
  [ "$cs" -ge "$ps" ] 2>/dev/null || problems+=("receipt count went DOWN: anchored #$ps, server now has #$cs (receipts removed or database replaced)")
  ch="$(j '.check_hash // ""')"
  [ "$ch" = "$ph" ] \
    || problems+=("hash at anchored receipt #$ps CHANGED: anchored ${ph:0:12}, server now ${ch:-nothing} (history was rewritten)")
fi

if [ ${#problems[@]} -eq 0 ]; then
  printf '%s\n' "$line" >> "$FILE" || fail3 "could not append to $FILE"
  commit "anchor $NAME $(j .at) #$(j .seq)"
  echo "[anchor $(now)] $NAME ok: chain intact, #$(j .seq) head $(j .head | cut -c1-12)"
  exit 0
fi

ts="$(now)"
jq -c -n --arg at "$ts" --argjson line "$line" --args '{rejected_at:$at, problems:$ARGS.positional, server_line:$line}' "${problems[@]}" >> "$REJ"
{ echo "=== $ts ALERT $NAME"; for p in "${problems[@]}"; do echo "  - $p"; done; } >> "$ALERTS"
commit "ALERT $NAME $ts: ${#problems[@]} problem(s)"
{ echo "## RAGNAROK RECEIPTS ALERT ($NAME, $ts)"; for p in "${problems[@]}"; do echo "##  - $p"; done
  echo "## Last good anchor: $FILE  evidence: $REJ"; } >&2
if [ "$NOTIFY" = 1 ] && command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${problems[0]//\"/\'}\" with title \"Receipts ALERT\" sound name \"Basso\"" >/dev/null 2>&1 || true
fi
exit 2
