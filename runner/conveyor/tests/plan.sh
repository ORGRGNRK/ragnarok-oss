#!/usr/bin/env bash
# plan.sh — planning first (SPEC-planning.md), proven with stub seats.
# NO MODEL IS CALLED: claude and grok below are shell scripts that answer the
# way the real CLIs' stream-json does, and choose their answer from the
# prompt (which seat they are being asked to be) and a SCENARIO word in the
# task. Every scenario drives the real conveyor-run.sh, one leg per call.
#
# ASSERTION COUNT IS ASSERTED, as in portable.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=48
# The belt runs on GNU tools (the conveyor wrapper puts Homebrew's first on a
# Mac); so does this test, or `date -Is` would quietly write empty times.
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

S="$(mktemp -d "${TMPDIR:-/tmp}/plan-test.XXXXXX")"; trap '[ -n "${KEEP:-}" ] || rm -rf "$S"' EXIT
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/bin" "$FAKEHOME/.grok/bin"
STUB="$FAKEHOME/bin/claude"
cat > "$STUB" <<'SEAT'
#!/usr/bin/env bash
# One stub, two names (claude, grok). Answers as planner, critic, executor or
# verifier depending on the prompt. Logs "<name> <role> <scenario> <round>".
me=$(basename "$0")
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
scn=$(printf '%s' "$prompt" | grep -oE 'SCENARIO=[a-z0-9]+' | head -1 | cut -d= -f2)
out=$(printf '%s' "$prompt" | grep -oE 'OUTFILE=[^ ]+' | head -1 | cut -d= -f2)
round=$(printf '%s' "$prompt" | grep -oE '^ROUND: [0-9]+' | head -1 | cut -d' ' -f2)
say() { jq -nc --arg t "$1" '{type:"result",subtype:"success",is_error:false,result:$t}'; }
role=executor
case "$prompt" in
  *"CONVEYOR PLANNER SEAT"*) role=planner ;;
  *"CONVEYOR CRITIC SEAT"*)  role=critic ;;
  *"CONVEYOR VERIFIER"*)     role=verifier ;;
esac
echo "$me $role $scn ${round:--}" >> "$STUB_LOG"
# Any edit a planner or critic makes to the task must be undone by the belt.
if [ "$role" = planner ] || [ "$role" = critic ]; then
  tf=$(ls "$CONVEYOR_ROOT"/running/*.md 2>/dev/null | head -1)
  [ -n "$tf" ] && echo "SEAT SCRIBBLE" >> "$tf"
fi
good="## Checklist
- [ ] the output file says hello :: verify: grep -qx hello $out"
case "$role" in
  planner)
    if [ "$scn" = unchecked ] && [ "$round" = 1 ]; then
      say "Here is my plan.
## Checklist
- [ ] the output file says hello :: verify: grep -qx hello $out
- [ ] tidy up afterwards
RESULT: plan"
    elif [ "$scn" = revise ] && [ "$round" = 2 ]; then
      say "Revised: added a line-count check.
$good
- [ ] the output file has exactly one line :: verify: test \"\$(wc -l < $out)\" -eq 1
RESULT: plan"
    else
      say "Plan:
$good
RESULT: plan"
    fi ;;
  critic)
    if [ "$scn" = deadlock ] || { [ "$scn" = revise ] && [ "$round" = 1 ]; }; then
      say "PROBLEM: nothing checks the file has only one line
VERDICT: problems"
    else
      say "Looks right.
VERDICT: approved"
    fi ;;
  verifier)
    say "CONFIRMED: the output file says hello
VERDICT: pass" ;;
  executor)
    # stepfail/stuck: the driver (claude) never does the work; grok (the
    # escalate seat) does.
    if { [ "$scn" != stepfail ] && [ "$scn" != stuck ] && [ "$scn" != plain ]; } || [ "$me" = grok ]; then
      printf 'hello\n' > "$out"
    fi
    say "Done.
RESULT: done" ;;
esac
SEAT
chmod +x "$STUB"; cp "$STUB" "$FAKEHOME/.grok/bin/grok"

newroot() { R="$S/$1"; mkdir -p "$R"/{plan,queue,running,verify,human,done,failed,logs}; : > "$S/stub.log"; }
belt() { # extra env... ; one runner invocation against $R
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT -u CONVEYOR_PLANNER_SEAT \
      -u CONVEYOR_CRITIC_SEAT -u CONVEYOR_ESCALATE_SEAT -u XAI_API_KEY \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 \
      CONVEYOR_CLAUDE="$FAKEHOME/bin/claude" CONVEYOR_GROK="$FAKEHOME/.grok/bin/grok" \
      CONVEYOR_DRIVER_SEAT=claude CONVEYOR_VERIFIER_SEAT=claude \
      STUB_LOG="$S/stub.log" "$@" bash "$RUN" >> "$R/belt.out" 2>&1
}
runs() { local n=$1 i; shift; for i in $(seq "$n"); do belt "$@"; done; }
plantask() { # name scenario [tray]
  cat > "$R/${3:-plan}/$1.md" <<T
# $1

SCENARIO=$2 Want: write the word hello into OUTFILE=$S/$1.out
T
}
stub_calls() { grep -c "$1" "$S/stub.log"; }

echo "-- A. conveyor add --plan; critic approves in round 1"
newroot approve
# CONVEYOR_PLAN_FORMAT=markdown: this suite is the markdown plan path; the
# JSON path (the json-tasks default) is tests/json-tasks.sh.
out=$(env CONVEYOR_ROOT="$R" CONVEYOR_PLAN_FORMAT=markdown bash "$PKG/conveyor" add "approve me" --plan -m "SCENARIO=approve1 Want: write hello into OUTFILE=$S/a.out" 2>&1)
f=$(ls "$R"/plan/*.md 2>/dev/null | head -1)
[ -n "$f" ] && ok "--plan puts the task in plan/, not queue/" || bad "--plan: nothing in plan/ ($out)"
printf '%s' "$out" | grep -q 'queued for planning' && ok "add says it is queued for planning" || bad "add output: $out"
t=$(basename "${f:-x}" .md)
belt
at "$t" queue
has "the approved plan is the live checklist" '^- \[ \] the output file says hello :: verify: grep' "$R/queue/$t.md"
has "the task says the plan was approved" '^## Plan approved — round 1' "$R/queue/$t.md"
has "the critic defaulted to a different seat (grok)" '^## Plan round 1 — critic \(grok\)' "$R/queue/$t.md"
hasnt "edits the planner/critic made to the task file were undone" 'SEAT SCRIBBLE' "$R/queue/$t.md"
[ "$(stub_calls 'claude planner')" = 1 ] && [ "$(stub_calls 'grok critic')" = 1 ] \
  && ok "one planner call (claude) and one critic call (grok)" || bad "stub calls: $(cat "$S/stub.log")"
has "a plan-approved receipt was written" '"verdict":"plan-approved"' "$R/logs/receipts.jsonl"

echo "-- B. critic objects, planner revises, critic approves"
newroot revise; plantask t-revise revise
belt
at t-revise plan
has "round 1 critique is in the task" 'PROBLEM: nothing checks the file has only one line' "$R/plan/t-revise.md"
hasnt "no live checklist while the plan is not approved" '^- \[ \] ' "$R/plan/t-revise.md"
belt
at t-revise queue
has "approved in round 2" '^## Plan approved — round 2' "$R/queue/t-revise.md"
has "the revised step is live" '^- \[ \] the output file has exactly one line :: verify:' "$R/queue/t-revise.md"
grep -q 'claude planner revise 2' "$S/stub.log" && ok "the planner was told it is round 2" || bad "no round-2 planner call: $(cat "$S/stub.log")"

echo "-- C. deadlock: still not approved after 2 rounds -> human/"
newroot deadlock; plantask t-dead deadlock
runs 2
at t-dead human
[ "$(grep -c '^## Plan round [12] — critic (grok)' "$R/human/t-dead.md")" = 2 ] \
  && ok "both rounds' critic notes are kept" || bad "critic notes missing"
[ "$(grep -c '^## Plan round [12] — planner (claude)' "$R/human/t-dead.md")" = 2 ] \
  && ok "both rounds' plans are kept" || bad "planner notes missing"
has "the operator gets an 'accept anyway' box" '^- \[ \] you accept this plan even though the critic did not approve it :: verify: HUMAN' "$R/human/t-dead.md"
has "an ask was filed for the operator" 'planner and critic did not agree' "$R/logs/human-inbox.jsonl"
# The operator approves: tick the box and send it on, as the app's Approve does.
sed -i.bak 's/^- \[ \] you accept this plan/- [x] you accept this plan/' "$R/human/t-dead.md" && rm -f "$R/human/t-dead.md.bak"
mv "$R/human/t-dead.md" "$R/queue/"
runs 3
at t-dead done

echo "-- D. a plan with an unchecked step is rejected before the critic sees it"
newroot unchecked; plantask t-unchecked unchecked
belt
at t-unchecked plan
has "the rejection names the step with no check" 'has no check: - \[ \] tidy up afterwards' "$R/plan/t-unchecked.md"
[ "$(stub_calls 'critic')" = 0 ] && ok "the critic was not spent on a rejected plan" || bad "critic was called: $(cat "$S/stub.log")"
has "a plan-rejected receipt was written" '"verdict":"plan-rejected"' "$R/logs/receipts.jsonl"
belt
at t-unchecked queue

echo "-- E. a step that fails 3 times goes to the escalate seat, once"
newroot stepfail; plantask t-step stepfail
runs 8 CONVEYOR_ESCALATE_SEAT=grok
at t-step done
has "the belt noted the escalation" '^## Leg [0-9]+ — step escalated' "$R/done/t-step.md"
[ "$(stub_calls 'claude executor stepfail')" = 3 ] && ok "the driver had exactly 3 tries" || bad "driver calls: $(stub_calls 'claude executor stepfail')"
[ "$(stub_calls 'grok executor stepfail')" = 1 ] && ok "the escalate seat got exactly one leg" || bad "escalate calls: $(stub_calls 'grok executor')"
grep -l 'escalated leg (grok seat)' "$R"/logs/*.log >/dev/null 2>&1 && ok "the escalated leg's log names its seat" || bad "no escalated leg log"
has "the escalated leg is on the receipts" '"seat":"escalated"' "$R/logs/receipts.jsonl"

echo "-- F. with no escalate seat, a step that fails 3 times parks on the operator"
newroot stuck; plantask t-stuck stuck
runs 6
at t-stuck human
has "a HUMAN box names the stuck step" '^- \[ \] you have looked at the stuck step "the output file says hello" and want the belt to try again \(stuck #1\) :: verify: HUMAN' "$R/human/t-stuck.md"
[ "$(stub_calls 'claude executor stuck')" = 3 ] && ok "it stopped after 3 tries, not at the leg ceiling" || bad "driver calls: $(stub_calls 'claude executor stuck')"
has "an ask was filed for the stuck step" 'stuck step' "$R/logs/human-inbox.jsonl"

echo "-- G. happy path: plan -> queue -> work -> verify -> done"
newroot happy; plantask t-happy happy
runs 4
at t-happy done
[ "$(cat "$S/t-happy.out" 2>/dev/null)" = hello ] && ok "the work was actually done" || bad "output file missing or wrong"
[ "$(stub_calls 'executor happy')" = 1 ] && [ "$(stub_calls 'verifier happy')" = 1 ] \
  && ok "one work leg and one verify leg" || bad "calls: $(cat "$S/stub.log")"
grep -q '"verdict":"verify-pass"' "$R/logs/receipts.jsonl" && ok "filed by the verifier as before" || bad "no verify-pass receipt"

echo "-- H. without --plan nothing changes"
newroot plain
out=$(env CONVEYOR_ROOT="$R" bash "$PKG/conveyor" add "plain" -m "x" 2>&1)
[ -n "$(ls "$R"/queue/*.md 2>/dev/null)" ] && [ -z "$(ls "$R"/plan/*.md 2>/dev/null)" ] \
  && ok "a plain add still goes straight to queue/" || bad "plain add: $out"
printf '%s' "$out" | grep -q '^queued: ' && ok "a plain add prints what it always printed" || bad "plain add output: $out"
rm -f "$R"/queue/*.md
cat > "$R/queue/t-plain.md" <<T
# t-plain

SCENARIO=plain OUTFILE=$S/t-plain.out

## Checklist
- [ ] the output file says hello :: verify: grep -qx hello $S/t-plain.out
T
runs 4 CONVEYOR_ESCALATE_SEAT=grok
at t-plain queue
hasnt "an unplanned task is never escalated or parked per step" 'step (escalated|stuck)' "$R/queue/t-plain.md"
[ "$(stub_calls 'grok')" = 0 ] && ok "the escalate seat was not used for it" || bad "grok was called: $(cat "$S/stub.log")"

echo "-- I. a missing critic leaves the task in plan/, and says why"
newroot nocritic; plantask t-nocritic approve1
belt CONVEYOR_CRITIC_SEAT=gemini CONVEYOR_GEMINI="$S/no-such-gemini"
at t-nocritic plan
has "the runner names the missing critic" 'plan stage: gemini seat selected but no binary' "$R/belt.out"

RAN=$((PASS+FAIL))
printf '\nplan.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
