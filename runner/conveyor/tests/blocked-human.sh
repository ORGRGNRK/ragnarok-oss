#!/usr/bin/env bash
# blocked-human.sh — a BLOCKED that is only waiting on the person lands in
# human/ ("Needs you"), where the app's Approve button works, instead of in
# failed/ ("Dead ends"), where no button can record a yes.
#
# NO MODEL IS CALLED: claude below is a shell script answering like the real
# CLI's stream-json. The executor stub says BLOCKED while the task file it is
# shown still has an open `verify: HUMAN` step, and done once it has none —
# what a real executor does when the only thing left is the person's call.
#
#   A. every command step passes, one HUMAN step open, seat says BLOCKED
#      -> human/, receipt blocked-human-wait, an inbox ask with the bare
#      ref, no ## Dead End, no dead-ends.jsonl line, the step still unticked.
#   B. the app's Approve (Belt.swift approve(): tick the first open HUMAN
#      line, human/ -> queue/) then two runs -> verify/ -> done/.
#   C. a FAILING command step + an open HUMAN step + BLOCKED -> still a dead end.
#   D. nothing open + BLOCKED -> still a dead end.
#   E. hand-tick guard intact: a seat that ticks the HUMAN box itself and
#      says BLOCKED has the tick erased and still parks in human/ unticked.
#   F. NEGATIVE CONTROL: the runner with the old BLOCKED line puts A's task
#      in failed/, so A can fail.
#
# ASSERTION COUNT IS ASSERTED, as in portable.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=24
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  bp="$(brew --prefix)"
  for d in "$bp/bin" "$bp/opt/flock/bin" "$bp/opt/gnu-sed/libexec/gnubin" "$bp/opt/coreutils/libexec/gnubin"; do
    [ -d "$d" ] && PATH="$d:$PATH"
  done; export PATH
fi
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()   { if grep -qE -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (/$2/ not in $3)"; fi; }
hasnt() { if grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1 (/$2/ found in $3)"; else ok "$1"; fi; }
at() { # name tray
  if [ -f "$R/$2/$1.md" ]; then ok "$1 is in $2/"
  else bad "$1 should be in $2/ but is at: $(cd "$R" && ls -d */"$1".md 2>/dev/null | tr '\n' ' ')"; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }

S="$(mktemp -d "${TMPDIR:-/tmp}/blocked-human.XXXXXX")"; trap '[ -n "${KEEP:-}" ] || rm -rf "$S"' EXIT
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/bin"
STUB="$FAKEHOME/bin/claude"
cat > "$STUB" <<'SEAT'
#!/usr/bin/env bash
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
say() { jq -nc --arg t "$1" '{type:"result",subtype:"success",is_error:false,result:$t}'; }
case "$prompt" in
  *"CONVEYOR VERIFIER"*) say "CONFIRMED: holds
VERDICT: pass"; exit 0 ;;
esac
if printf '%s\n' "$prompt" | grep -q '^- \[ \] .*:: verify: HUMAN'; then
  if printf '%s' "$prompt" | grep -q 'SCENARIO=forge'; then
    tf=$(ls "$CONVEYOR_ROOT"/running/*.md 2>/dev/null | head -1)
    [ -n "$tf" ] && sed -i 's/^- \[ \] \(.*:: verify: HUMAN\)/- [x] \1/' "$tf"
  fi
  say "Everything builds.
RESULT: blocked — waiting on the operator to confirm"
else
  say "Done.
RESULT: done"
fi
SEAT
chmod +x "$STUB"

newroot() { R="$S/$1"; mkdir -p "$R"/{plan,queue,running,verify,human,done,failed,logs}; }
belt() { # [runner]
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT -u CONVEYOR_PLANNER_SEAT \
      -u CONVEYOR_CRITIC_SEAT -u CONVEYOR_ESCALATE_SEAT -u XAI_API_KEY \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 \
      CONVEYOR_CLAUDE="$STUB" CONVEYOR_DRIVER_SEAT=claude CONVEYOR_VERIFIER_SEAT=claude \
      bash "${1:-$RUN}" >> "$R/belt.out" 2>&1
}
last_verdict() { tail -1 "$R/logs/receipts.jsonl" | jq -r .verdict; }
mktask() { # name command-step [scenario]
  printf 'here\n' > "$S/$1.out"
  cat > "$R/queue/$1.md" <<T
# $1

SCENARIO=${3:-plain} Want: a small thing that is already built.

## Legs: 2

## Checklist
- [ ] the output file exists :: verify: $2
- [ ] the operator confirms the result :: verify: HUMAN
T
}
# The app's Approve, local belt (Sources/Conveyor/Belt.swift approve()).
app_approve() { # name
  local f="$R/human/$1.md"
  python3 - "$f" <<'PY' || return 1
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    if l.startswith("- [ ]") and ":: verify: HUMAN" in l:
        lines[i] = "- [x]" + l[5:]; break
else:
    sys.exit(1)
open(p, "w").write("\n".join(lines))
PY
  mv "$f" "$R/queue/"
}

echo "-- A. BLOCKED with only a HUMAN step open -> Needs you"
newroot a; mktask t-a "test -s $S/t-a.out"
belt
at t-a human
eq "receipt verdict is blocked-human-wait" blocked-human-wait "$(last_verdict)"
has "the ask is in the local inbox with the bare ref" '"itemRef":"conveyor:t-a\.md"' "$R/logs/human-inbox.jsonl"
hasnt "and it is not a dead-end ask" 'conveyor:t-a\.md:dead-end' "$R/logs/human-inbox.jsonl"
hasnt "no ## Dead End block" '^## Dead End' "$R/human/t-a.md"
[ -s "$R/logs/dead-ends.jsonl" ] && bad "a dead-ends.jsonl line was written" || ok "no dead-ends.jsonl line"
has "the seat's words are on the record" 'waiting on the operator to confirm' "$R/human/t-a.md"
has "and why it was parked" 'not a dead end\. Parked in human/' "$R/human/t-a.md"
has "the HUMAN step is still unticked (the AI cannot approve)" '^- \[ \] the operator confirms the result :: verify: HUMAN' "$R/human/t-a.md"

echo "-- B. the app's Approve, then the belt finishes it"
app_approve t-a && ok "Approve ticks the step and moves it to queue/" || bad "Approve failed"
at t-a queue
belt
at t-a verify
belt
at t-a done
has "the person's tick survived both legs" '^- \[x\] the operator confirms the result :: verify: HUMAN' "$R/done/t-a.md"

echo "-- C. a failing command step is still a dead end"
newroot c; mktask t-c "false"
belt
at t-c failed
eq "receipt verdict stays blocked" blocked "$(last_verdict)"
has "with a ## Dead End block" '^## Dead End' "$R/failed/t-c.md"

echo "-- D. nothing open is still a dead end"
newroot d
cat > "$R/queue/t-d.md" <<'T'
# t-d

## Legs: 1

## Checklist
- [ ] says OK :: verify: echo OK :: expect: ^OK$
- [ ] the operator confirms the result :: verify: HUMAN
T
# the HUMAN step already ticked (a past yes) and nothing else open
sed -i 's/^- \[ \] the operator/- [x] the operator/' "$R/queue/t-d.md"
cat > "$S/d-stub" <<'SEAT'
#!/usr/bin/env bash
jq -nc '{type:"result",subtype:"success",is_error:false,result:"RESULT: blocked — just because"}'
SEAT
chmod +x "$S/d-stub"
env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT HOME="$FAKEHOME" CONVEYOR_ROOT="$R" \
    CONVEYOR_STANDALONE=1 CONVEYOR_CLAUDE="$S/d-stub" CONVEYOR_DRIVER_SEAT=claude CONVEYOR_VERIFIER_SEAT=claude \
    bash "$RUN" >> "$R/belt.out" 2>&1
at t-d failed
eq "receipt verdict stays blocked" blocked "$(last_verdict)"

echo "-- E. a seat that ticks the HUMAN box itself gets the tick erased"
newroot e; mktask t-e "test -s $S/t-e.out" forge
belt
at t-e human
has "the forged tick is gone" '^- \[ \] the operator confirms the result :: verify: HUMAN' "$R/human/t-e.md"
has "and the erase is on the record" 'hand-ticks erased: .*HUMAN step.*forgery' "$R/human/t-e.md"

echo "-- F. negative control: the old BLOCKED routing dead-ends A's shape"
newroot f; mktask t-f "test -s $S/t-f.out"
OLD="$S/old"; mkdir -p "$OLD"
for x in "$PKG"/*; do [ "$(basename "$x")" = conveyor-run.sh ] || ln -s "$x" "$OLD/$(basename "$x")"; done
sed 's|^\( *\)"RESULT: blocked"\*) route_blocked "$final" ;;$|\1"RESULT: blocked"*) dead_end "seat reported BLOCKED"; verdict=blocked ;;|' "$RUN" > "$OLD/conveyor-run.sh"
if grep -q 'route_blocked "$final"' "$OLD/conveyor-run.sh"; then bad "mutation did not apply"; else ok "mutation applied"; fi
belt "$OLD/conveyor-run.sh"
at t-f failed

echo
echo "blocked-human.sh: $PASS passed, $FAIL failed ($((PASS+FAIL))/$EXPECTED assertions ran)"
[ "$FAIL" -eq 0 ] && [ $((PASS+FAIL)) -eq "$EXPECTED" ]
