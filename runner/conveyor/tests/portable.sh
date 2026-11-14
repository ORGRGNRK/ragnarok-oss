#!/usr/bin/env bash
# portable.sh — this RELEASE runs, and carries nothing of the machine it came from.
#
# WHY THE RELEASE HAS ITS OWN SUITE. The author's tests/standalone.sh proves the
# standalone MODE works inside his package, and its case E uses his own
# preambles as a positive control — files this release deliberately does not
# ship. A suite that cannot run against the artifact it ships with proves
# nothing about that artifact. So this one tests the extract: it starts, it
# still refuses to run half-blind, its bundled tools write, and it carries no
# instance state.
#
# ASSERTION COUNT IS ASSERTED. Every check moves a counter and the total is
# compared at the end. The upstream suite once reported "8 passed, 0 failed"
# while three assertions never ran at all, because they called helpers that did
# not exist yet. A suite that reports green on checks that never executed is the
# defect this whole package exists to catch, produced inside its own tests.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=13
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s (want %q, got %q)\n' "$1" "$2" "$3"; fi
}
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
contains() {
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s (%q not in %s)\n' "$1" "$2" "$3"; fi
}

R="$(mktemp -d)"; FAKEHOME="$(mktemp -d)"
trap 'rm -rf "$R" "$FAKEHOME"' EXIT
mkdir -p "$R"/{queue,running,verify,human,done,failed,logs}

# A stranger's machine. It DOES get a stub seat: needing one of claude/codex/
# gemini is the product, not a coupling. The queue is left empty on purpose, so
# this exercises preflight only and no model is ever called.
mkdir -p "$FAKEHOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$FAKEHOME/.local/bin/claude"
chmod +x "$FAKEHOME/.local/bin/claude"
belt() {
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" "$@" bash "$RUN" 2>&1
}

echo "-- A. the release starts on a machine that is not the author's"
outA="$(belt CONVEYOR_STANDALONE=1)"; rcA=$?
check "exits 0" 0 "$rcA"
printf '%s\n' "$outA" > "$R/a.out"
if grep -q 'notify sender not found\|receipt writer not found' "$R/a.out"; then
  bad "preflight still refuses under standalone"
else ok "preflight passes under standalone"; fi

echo "-- B. NEGATIVE CONTROL: without the flag it must STILL die"
outB="$(belt)"; rcB=$?
printf '%s\n' "$outB" > "$R/b.out"
if [ "$rcB" -ne 0 ]; then ok "exits nonzero without the flag"
else bad "exited 0 without the flag — the guard is GONE, not redirected"; fi
contains "still names what is missing" "notify sender not found" "$R/b.out"

echo "-- C. the bundled tools actually write, so a loss is still surfaced"
CONVEYOR_ROOT="$R" "$PKG/standalone/notify-local" --b64 "$(printf 'DEAD END: t1' | base64 -w0)" 2>/dev/null
contains "notify-local wrote the notice" "DEAD END: t1" "$R/logs/notify.log"
CONVEYOR_ROOT="$R" "$PKG/standalone/receipt-local" t1 "no new ticks" "REFUTED" "$R/failed/t1.md"
contains "receipt-local wrote the dead end" '"task":"t1"' "$R/logs/dead-ends.jsonl"
CONVEYOR_ROOT="$R" "$PKG/standalone/close-local" t1 pending failed "$(date -u +%FT%TZ)"
contains "close-local wrote the outcome" '"task":"t1"' "$R/logs/closed.jsonl"

echo "-- D. a receipt that cannot be written still fails loudly"
CONVEYOR_ROOT="/proc/nonexistent" "$PKG/standalone/receipt-local" t2 x y z >/dev/null 2>&1
if [ $? -ne 0 ]; then ok "receipt-local exits nonzero when it cannot write"
else bad "receipt-local swallowed an unwritable receipt"; fi

echo "-- E. nothing here breaks on another machine"
# NOT a name scan. The design comments name the author and his box deliberately
# — that is the reasoning behind each rule and it ships. What must not ship is a
# path the shell actually RUNS or a credential: either one is broken or unsafe
# the moment this lands anywhere else.
# This file is excluded from its own scan: it plants these strings below as
# positive controls, and a scanner that matches its own pattern text reports a
# leak that is only ever itself.
breakers() { grep -rnE '/home/[a-z]|/Users/[a-z]' "$1" --exclude-dir=.git --exclude=.git --exclude=portable.sh 2>/dev/null \
               | grep -vE ':[0-9]+:[[:space:]]*#' || true; }
creds()    { grep -rnE 'sk-ant-|nc_pat_|pat[A-Za-z0-9]{14,}|gh[pousr]_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}|xox[bap]-|BEGIN [A-Z ]*PRIVATE KEY' \
               "$1" --exclude-dir=.git --exclude=.git --exclude=portable.sh 2>/dev/null || true; }
b="$(breakers "$PKG")"; c="$(creds "$PKG")"
if [ -n "$b$c" ]; then printf '%s\n%s\n' "$b" "$c" | sed 's/^/       /'
  bad "an executable path or a credential shipped"
else ok "no executable absolute path, no credential"; fi
# Positive controls: an empty result above must mean the tree is clean, not that
# the patterns are broken. And the path scan must NOT fire on a comment, or the
# design comments could never ship.
P="$R/probe"; mkdir -p "$P"
printf 'ExecStart=/home/someone/x\n' > "$P/a"; printf 'K=sk-ant-0000000000\n' > "$P/b"
if [ -n "$(breakers "$P")" ] && [ -n "$(creds "$P")" ]; then ok "both scans are real"
else bad "a scan matches nothing — an empty result proves nothing"; fi
rm -f "$P/a" "$P/b"
printf '  # note: /home/someone/x is where it used to live\n' > "$P/c"
if [ -z "$(breakers "$P")" ]; then ok "a commented path is not a breaker"
else bad "the scan fires on comments — it would strip the reasoning"; fi

echo "-- F. no instance state shipped"
n=$(find "$PKG"/queue "$PKG"/running "$PKG"/verify "$PKG"/human "$PKG"/done "$PKG"/failed \
      -name '*.md' 2>/dev/null | wc -l | tr -d " ")
check "no task files in the state directories" 0 "$n"
n=$(find "$PKG/logs" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d " ")
check "no logs shipped" 0 "$n"

RAN=$((PASS+FAIL))
printf '\nportable.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
