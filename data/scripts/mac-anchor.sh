#!/usr/bin/env bash
# scripts/mac-anchor.sh -- runs on the MAC (hourly, via launchd). Keeps an off-server copy of the
# receipt chain's head hashes so a rewritten history on the server can be caught later.
#
# Each run:
#   1. SSHes to the server and runs `./kit anchor <last write_log seq> <last access_log seq>`.
#   2. Compares the answer with the last GOOD anchor kept here:
#        - the server's own verify must say intact + locked
#        - neither log's seq may go DOWN
#        - the hash the server holds NOW at each previously anchored seq must be the SAME hash
#   3. Good  -> appends the line to  $ANCHOR_DIR/<name>.jsonl  and commits it (local git repo).
#      Bad   -> does NOT touch <name>.jsonl (so every later run keeps comparing against the last
#               good anchor and keeps alerting); writes the evidence to <name>.rejected.jsonl and
#               <name>.alerts.log, prints a loud ALERT on stderr, shows a macOS notification, exit 2.
# Exit codes: 0 ok, 2 TAMPER/BROKEN alert, 3 could not reach or read the server (not a tamper sign).
#
# Settings (environment variables; the launchd plist sets them):
#   ANCHOR_SSH_TARGET   user@host of the server owner      (default alexus)
#   ANCHOR_SSH_KEY      private key for the anchor-only SSH key (optional)
#   ANCHOR_REMOTE_CMD   what to run remotely (default "anchor", for the forced-command gate
#                       scripts/anchor-ssh-gate.sh; without the gate use
#                       "cd ~/Developer/ragnarok/data && ./kit anchor")
#   ANCHOR_DIR          where anchors are kept            (default ~/RAGNAROK-anchors)
#   ANCHOR_NAME         file name                          (default ragnarok-data)
#   ANCHOR_APPEND_ONLY  1 = set the macOS append-only flag (chflags uappnd) on the files (default 1)
#   ANCHOR_NOTIFY       1 = macOS notification on alerts (default 1)
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

TARGET="${ANCHOR_SSH_TARGET:-alexus}"
KEY="${ANCHOR_SSH_KEY:-}"
REMOTE="${ANCHOR_REMOTE_CMD:-anchor}"
DIR="${ANCHOR_DIR:-$HOME/RAGNAROK-anchors}"
NAME="${ANCHOR_NAME:-ragnarok-data}"
SSH_BIN="${ANCHOR_SSH:-ssh}"          # tests swap in a fake
APPEND_ONLY="${ANCHOR_APPEND_ONLY:-1}"
NOTIFY="${ANCHOR_NOTIFY:-1}"
FILE="$DIR/$NAME.jsonl"; REJ="$DIR/$NAME.rejected.jsonl"; ALERTS="$DIR/$NAME.alerts.log"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fail3() { echo "[anchor $(now)] $NAME: $*" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || fail3 "jq is needed (macOS 15+ has /usr/bin/jq; or: brew install jq)"

mkdir -p "$DIR" || fail3 "cannot create $DIR"
lock="$DIR/.$NAME.lock"
mkdir "$lock" 2>/dev/null || fail3 "another run is in progress (remove $lock if it is stale)"
trap 'rmdir "$lock" 2>/dev/null' EXIT

if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q || fail3 "git init failed in $DIR"
  printf '.*.lock/\n' > "$DIR/.gitignore"
fi
for f in "$FILE" "$REJ" "$ALERTS"; do
  if [ ! -e "$f" ]; then : > "$f"; [ "$APPEND_ONLY" = 1 ] && chflags uappnd "$f" 2>/dev/null; fi
done

commit() {   # commit whatever changed; a failed commit never loses the appended line
  git -C "$DIR" add -A >/dev/null 2>&1
  git -C "$DIR" -c user.name="${ANCHOR_GIT_NAME:-RAGNAROK anchor}" -c user.email="${ANCHOR_GIT_EMAIL:-anchor@localhost}" \
    commit -q -m "$1" >/dev/null 2>&1 || git -C "$DIR" diff --cached --quiet || echo "[anchor] warning: git commit failed in $DIR" >&2
}

# ---- the last good anchor
prev="$(grep -v '^[[:space:]]*$' "$FILE" | tail -1)"
pw=0; pa=0; pwh=""; pah=""; pproj=""
if [ -n "$prev" ]; then
  echo "$prev" | jq -e . >/dev/null 2>&1 || fail3 "the last line of $FILE is not valid JSON; fix by hand"
  pw="$(echo "$prev" | jq -r '.write_log_seq')";  pwh="$(echo "$prev" | jq -r '.write_log_head // ""')"
  pa="$(echo "$prev" | jq -r '.access_log_seq')"; pah="$(echo "$prev" | jq -r '.access_log_head // ""')"
  pproj="$(echo "$prev" | jq -r '.project')"
fi

# ---- ask the server
sshopts=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
[ -n "$KEY" ] && sshopts+=(-i "$KEY" -o IdentitiesOnly=yes)
line="$("$SSH_BIN" "${sshopts[@]}" "$TARGET" "$REMOTE $pw $pa" 2>"$DIR/.$NAME.ssh-err")"; rc=$?
line="$(printf '%s\n' "$line" | grep '^{' | tail -1)"
if [ -z "$line" ] || ! echo "$line" | jq -e '.v == 1 and (.project | type == "string")' >/dev/null 2>&1; then
  err="$(tail -3 "$DIR/.$NAME.ssh-err" 2>/dev/null | tr '\n' ' ')"; rm -f "$DIR/.$NAME.ssh-err"
  fail3 "could not get an anchor from $TARGET (exit $rc): ${err:-no output}"
fi
rm -f "$DIR/.$NAME.ssh-err"

# ---- compare
problems=()
j() { echo "$line" | jq -r "$1"; }
[ "$(j '.intact')" = true ] || problems+=("server verify is NOT clean: write_log intact=$(j .write_log_intact) lock=$(j .write_log_lock), access_log intact=$(j .access_log_intact) lock=$(j .access_log_lock)")
if [ -n "$prev" ]; then
  [ "$(j .project)" = "$pproj" ] || problems+=("project changed: anchored '$pproj', server now says '$(j .project)' (wrong server or a rebuilt stack?)")
  cw="$(j .write_log_seq)"; ca="$(j .access_log_seq)"
  [ "$cw" -ge "$pw" ] 2>/dev/null || problems+=("write_log seq went DOWN: anchored #$pw, server now has #$cw (receipts were removed or the database was replaced)")
  [ "$ca" -ge "$pa" ] 2>/dev/null || problems+=("access_log seq went DOWN: anchored #$pa, server now has #$ca (log rows were removed or the database was replaced)")
  if [ "$pw" -gt 0 ]; then
    [ "$(j .check_write_log_seq)" = "$pw" ] && [ "$(j '.check_write_log_hash // ""')" = "$pwh" ] \
      || problems+=("write_log hash at anchored #$pw CHANGED: anchored $pwh, server now has $(j '.check_write_log_hash // "nothing"') (history was rewritten)")
  fi
  if [ "$pa" -gt 0 ]; then
    [ "$(j .check_access_log_seq)" = "$pa" ] && [ "$(j '.check_access_log_hash // ""')" = "$pah" ] \
      || problems+=("access_log hash at anchored #$pa CHANGED: anchored $pah, server now has $(j '.check_access_log_hash // "nothing"') (history was rewritten)")
  fi
fi

if [ ${#problems[@]} -eq 0 ]; then
  printf '%s\n' "$line" >> "$FILE" || fail3 "could not append to $FILE"
  commit "anchor $NAME $(j .at) write_log#$(j .write_log_seq) access_log#$(j .access_log_seq)"
  echo "[anchor $(now)] $NAME ok: write_log #$(j .write_log_seq) access_log #$(j .access_log_seq)"
  exit 0
fi

# ---- ALERT: keep the evidence, leave the good-anchor file alone, shout
ts="$(now)"
jq -c -n --arg at "$ts" --argjson line "$line" --args '{rejected_at: $at, problems: $ARGS.positional, server_line: $line}' "${problems[@]}" >> "$REJ"
{ echo "=== $ts ALERT $NAME"; for p in "${problems[@]}"; do echo "  - $p"; done; } >> "$ALERTS"
commit "ALERT $NAME $ts: ${#problems[@]} problem(s)"
{
  echo "############################################################"
  echo "## RAGNAROK ANCHOR ALERT ($NAME, $ts)"
  for p in "${problems[@]}"; do echo "##  - $p"; done
  echo "## Last good anchor kept in $FILE; evidence in $REJ"
  echo "############################################################"
} >&2
if [ "$NOTIFY" = 1 ] && command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${problems[0]//\"/\'}\" with title \"RAGNAROK anchor ALERT ($NAME)\" sound name \"Basso\"" >/dev/null 2>&1 || true
fi
exit 2
