#!/usr/bin/env bash
# Fixtures for ~/scripts/git-history-scan.
#
# Hermetic: builds throwaway git repos in a temp dir, injects fake credential
# values through the $GHS_SECRETS_FILE seam. Never reads a real .env, never
# contacts Airtable, never touches a real repo.
#
# The load-bearing cases are the NEGATIVE CONTROLS (marked NC): a scanner that
# prints the secret it just found is a second copy of the leak, so "the fake
# value appears ZERO times in stdout and in the report file" is asserted
# explicitly, both tiers. If it ever starts printing values, these fail.

set -u
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # Linux or Mac

SCAN="${GHS_SCAN:-$(cd "$(dirname "$0")/.." && pwd)/git-history-scan}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (found forbidden string)";; *) ok "$1";; esac; }

# Fake values. Shaped like the real thing so PATTERNS fires, but not real keys.
FAKE_ANT="sk-ant-api03-FIXTUREfixtureFIXTUREfixture000000"
FAKE_LIVE="fixture-live-value-0123456789abcdef"
FAKE_SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

printf '%s\n' "$FAKE_LIVE" > "$TMP/secrets.txt"
export GHS_SECRETS_FILE="$TMP/secrets.txt"
export GHS_STATE_DIR="$TMP/state"

mkrepo() {
  d="$TMP/$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email fixture@example.com
  git -C "$d" config user.name Fixture
  echo "$d"
}

# ---------------------------------------------------------------------------
echo "-- case 1-6: a deleted credential file is still in history"
R="$(mkrepo leaky)"
printf 'ANTHROPIC_API_KEY=%s\nTOKEN=%s\n' "$FAKE_ANT" "$FAKE_LIVE" > "$R/.env"
git -C "$R" add -f .env >/dev/null 2>&1
git -C "$R" commit -qm "add config"
git -C "$R" rm -q .env
echo "clean" > "$R/README.md"
git -C "$R" add README.md; git -C "$R" commit -qm "strip creds, add readme"

OUT="$("$SCAN" "$R" --report "$TMP/r1.json" 2>&1)"; RC=$?

check "exit 1 when findings exist" "$RC" "1"
has  "reports the LIVE tier"        "$OUT" "LIVE "
has  "reports the anthropic shape"  "$OUT" "anthropic-key"
has  "flags it HISTORY-ONLY"        "$OUT" "HISTORY-ONLY"
has  "names the .env path"          "$OUT" ".env"
if [ "$(grep -c 'introduced/removed in' <<<"$OUT")" -ge 1 ]; then
  ok "names an introducing commit"; else bad "names an introducing commit"; fi

echo "-- case 7-10: NC — the secret value is never emitted"
hasnt "NC: live value absent from stdout"  "$OUT" "$FAKE_LIVE"
hasnt "NC: shape value absent from stdout" "$OUT" "$FAKE_ANT"
REPORT="$(cat "$TMP/r1.json")"
hasnt "NC: live value absent from report"  "$REPORT" "$FAKE_LIVE"
hasnt "NC: shape value absent from report" "$REPORT" "$FAKE_ANT"

echo "-- case 11-12: report file is 0600 and holds fingerprints"
MODE="$(mode_of "$TMP/r1.json")"
check "report is mode 0600" "$MODE" "600"
has "report carries a fingerprint" "$REPORT" "fingerprint"

echo "-- case 13-15: NC — a clean repo is clean"
R2="$(mkrepo clean)"
echo "just some code" > "$R2/main.py"; git -C "$R2" add main.py; git -C "$R2" commit -qm init
OUT2="$("$SCAN" "$R2" --report "$TMP/r2.json" 2>&1)"; RC2=$?
check "exit 0 on a clean repo" "$RC2" "0"
has  "says nothing was found"   "$OUT2" "no credential shapes found"
hasnt "no HISTORY-ONLY line"    "$OUT2" "HISTORY-ONLY"

echo "-- case 16-17: NC — a bare 64-hex sha is not a credential"
R3="$(mkrepo shas)"
printf 'commit %s\nsha256:%s\n' "$FAKE_SHA" "$FAKE_SHA" > "$R3/notes.md"
git -C "$R3" add notes.md; git -C "$R3" commit -qm shas
OUT3="$("$SCAN" "$R3" --report "$TMP/r3.json" 2>&1)"; RC3=$?
check "NC: bare hex does not trigger findings" "$RC3" "0"
has  "NC: clean verdict on a sha-only repo"    "$OUT3" "no credential shapes found"

echo "-- case 18-19: a secret still present in HEAD reads IN HEAD"
R4="$(mkrepo current)"
printf 'key=%s\n' "$FAKE_ANT" > "$R4/config.txt"
git -C "$R4" add config.txt; git -C "$R4" commit -qm add
OUT4="$("$SCAN" "$R4" --report "$TMP/r4.json" 2>&1)"
has  "flags IN HEAD"                 "$OUT4" "IN HEAD"
hasnt "does not mislabel as history" "$OUT4" "HISTORY-ONLY"

echo "-- case 20-21: history reachable only from a non-HEAD branch is scanned"
R5="$(mkrepo sidebranch)"
echo base > "$R5/a.txt"; git -C "$R5" add a.txt; git -C "$R5" commit -qm base
BASE_BRANCH="$(git -C "$R5" rev-parse --abbrev-ref HEAD)"
git -C "$R5" checkout -qb side
printf 'k=%s\n' "$FAKE_ANT" > "$R5/leak.txt"
git -C "$R5" add leak.txt; git -C "$R5" commit -qm leak
git -C "$R5" checkout -q "$BASE_BRANCH"
# HEAD is now the base branch, so the leaking blob is reachable ONLY from the
# side branch. A working-tree scanner sees nothing here; this must not.
OUT5="$("$SCAN" "$R5" --report "$TMP/r5.json" 2>&1)"
has  "finds a blob on another branch" "$OUT5" "anthropic-key"
has  "and calls it HISTORY-ONLY"      "$OUT5" "HISTORY-ONLY"
hasnt "NC: still never prints it"     "$OUT5" "$FAKE_ANT"

echo "-- case 22-23: degraded live tier is announced, never silent"
OUT6="$(GHS_SECRETS_FILE= "$SCAN" "$R2" --shapes-only --report "$TMP/r6.json" 2>&1)"
has "announces the degraded live tier" "$OUT6" "LIVE TIER DEGRADED"
has "warns 0 LIVE is not a clean bill"  "$OUT6" "does NOT mean"

echo "-- case 24-25: a linked worktree / non-repo is refused, not silently skipped"
mkdir -p "$TMP/notarepo"
OUT7="$("$SCAN" "$TMP/notarepo" 2>&1)"; RC7=$?
check "exit 2 on a non-repository" "$RC7" "2"
has  "says why"                    "$OUT7" "not a repository"

echo "-- case 26: json mode emits parseable json"
if "$SCAN" "$R2" --json --report "$TMP/r7.json" 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)'; then
  ok "json mode parses"; else bad "json mode parses"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
