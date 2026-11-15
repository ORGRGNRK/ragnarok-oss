#!/usr/bin/env bash
# scripts/test-local.sh -- quick checks that need NO Docker, NO database and NO network.
# Safe to run anywhere (it never talks to a real stack: docker compose is replaced by a fake that
# only records whether it was called). Run: ./scripts/test-local.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fails=0; passes=0
ok()  { printf '  PASS  %s\n' "$*"; passes=$((passes+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails+1)); }

# A fake settings file and a fake "docker compose" that logs every call and pretends to be psql.
cat > "$tmp/env" <<'ENV'
COMPOSE_PROJECT_NAME=local-test
POSTGRES_DB=clientdata
POSTGRES_USER=kit_admin
POSTGRES_PASSWORD=not-a-real-password
ENV
cat > "$tmp/fake-compose" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
cat >/dev/null 2>&1 || true
echo "${FAKE_PSQL_OUT:-Archive things #1 (fake)}"
FAKE
chmod +x "$tmp/fake-compose"
export KIT_ENV_FILE="$tmp/env" COMPOSE="$tmp/fake-compose" FAKE_LOG="$tmp/compose.log"

echo "== ./kit approve: a person at a terminal only"
: > "$FAKE_LOG"
out="$("$ROOT/kit" approve ARC-TESTCODE < /dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "non-TTY stdin (/dev/null) -> refused (exit $rc)" || bad "non-TTY stdin was NOT refused (exit 0): $out"
case "$out" in *"not a TTY"*) ok "the refusal says why (stdin is not a TTY)";; *) bad "unexpected message: $out";; esac
[ ! -s "$FAKE_LOG" ] && ok "refused before touching the database (docker compose never called)" || bad "docker compose was called: $(cat "$FAKE_LOG")"

: > "$FAKE_LOG"
out="$(printf 'yes\n' | "$ROOT/kit" approve ARC-TESTCODE 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ ! -s "$FAKE_LOG" ] && ok "piping 'yes' into it -> refused, nothing called" || bad "piped yes: exit $rc, $out"

: > "$FAKE_LOG"
out="$("$ROOT/kit" approve ARC-TESTCODE --yes < /dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ ! -s "$FAKE_LOG" ] && ok "--yes bypass is gone (refused, nothing called)" || bad "--yes: exit $rc, $out"

# Positive control: under a pseudo-terminal it gets past the TTY check and asks the question.
# (This also shows the honest limit: a pseudo-terminal can be faked by anyone with a full shell.)
if [ "$(uname)" = Darwin ] && command -v script >/dev/null 2>&1; then
  : > "$FAKE_LOG"
  out="$(printf 'no\n' | script -q /dev/null "$ROOT/kit" approve ARC-TESTCODE 2>&1)"; rc=$?
  case "$out" in *"Type yes"*) [ -s "$FAKE_LOG" ] && ok "control: at a (pseudo) terminal it shows the request and asks; answering no -> not approved" || bad "control: asked but compose not called";;
    *) bad "control: at a terminal it did not ask (exit $rc): $out";; esac
else
  echo "  SKIP  terminal control check (needs macOS 'script')"
fi

echo ""; echo "== ./kit anchor (fake database answer)"
h="$(printf '%064d' 7)"
: > "$FAKE_LOG"
out="$(FAKE_PSQL_OUT="2026-10-30T19:00:00Z|t|5|$h|t|t|10|$h|t|t|$h||3|$h|t|t|" "$ROOT/kit" anchor 5 0 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | jq -e '.v==1 and .project=="local-test" and .intact==true and .write_log_seq==5 and .write_log_head=="'"$h"'" and .access_log_seq==10 and .check_write_log_seq==5 and .check_write_log_hash=="'"$h"'" and .check_access_log_hash==null and .agent_log_seq==3 and .agent_log_head=="'"$h"'" and .agent_log_intact==true' >/dev/null 2>&1
then ok "prints one valid JSON line with seqs, head hashes and the check hash"; else bad "anchor output (exit $rc): $out"; fi
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok "exactly one line" || bad "more than one line: $out"
out="$(FAKE_PSQL_OUT="2026-10-30T19:00:00Z|f|5||f|t|10|$h|t|t|||0||t|t|" "$ROOT/kit" anchor 2>/dev/null)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | jq -e '.intact==false and .write_log_head==null' >/dev/null 2>&1 && ok "broken chain -> line still printed, intact false, exit 1" || bad "broken: exit $rc: $out"
: > "$FAKE_LOG"
"$ROOT/kit" anchor 5 'x;ls' >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -s "$FAKE_LOG" ] && ok "non-number seq refused before touching the database" || bad "bad seq: exit $rc"

echo ""; echo "== scripts/anchor-ssh-gate.sh (the anchor key can only run anchor)"
gate="$ROOT/scripts/anchor-ssh-gate.sh"
for cmd in "rm -rf /tmp/x" "anchor; id" "anchor ; id" "anchor 1 \$(id)" "anchor 1 2 3 4" "bash" "anchor 1 *"; do
  : > "$FAKE_LOG"
  SSH_ORIGINAL_COMMAND="$cmd" "$gate" >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && [ ! -s "$FAKE_LOG" ] && ok "gate refuses: $cmd" || bad "gate allowed: $cmd (exit $rc)"
done
out="$(SSH_ORIGINAL_COMMAND="anchor 5 0" FAKE_PSQL_OUT="2026-10-30T19:00:00Z|t|5|$h|t|t|10|$h|t|t|$h||3|$h|t|t|" "$gate" 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | jq -e '.check_write_log_seq==5' >/dev/null 2>&1 && ok "gate runs: anchor 5 0" || bad "gate anchor: exit $rc: $out"

if [ -f "$ROOT/scripts/test-anchor.sh" ]; then
  echo ""; "$ROOT/scripts/test-anchor.sh"; r=$?; [ $r -eq 0 ] || fails=$((fails+1))
fi

echo ""
if [ $fails -eq 0 ]; then echo "LOCAL CHECKS PASSED ($passes)"; exit 0; fi
echo "LOCAL CHECKS FAILED ($fails)"; exit 1
