#!/usr/bin/env bash
# dead-end-demo.sh — watch the belt refuse a lie, then stop and explain itself.
#
# Runs the REAL runner, the REAL checker and the REAL stop rule against a
# scratch directory, with one thing stubbed: the AI seat. The stub always
# answers "RESULT: done" no matter what it was asked. That is the demo. Every
# agent runner in the world would file that as finished; this one re-runs the
# checklist, finds the claim unproved, and walks the task back.
#
# NOTHING IS SPENT AND NOTHING OF YOURS IS TOUCHED. No model is called, no
# network is used, and all state lives in a temp directory that is deleted on
# exit. You do not need a seat installed or authenticated to run this.
#
# What you are about to read at the end is examples/dead-end-demo.md as the
# belt left it: every leg's reasoning appended in order, then a Dead End block
# naming the rule that fired. That file IS the loss record.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export CONVEYOR_STANDALONE=1
export CONVEYOR_ROOT="$SCRATCH/root"
export CONVEYOR_CLAUDE="$SCRATCH/lying-seat"
export CONVEYOR_DRIVER_SEAT=claude
export CONVEYOR_VERIFIER_SEAT=claude
# The real default is 10. Lowered here only so the demo is short enough to
# read: the rule being demonstrated is the ceiling itself, not its value.
export CONVEYOR_LEG_CEILING=3
mkdir -p "$CONVEYOR_ROOT"/{queue,running,verify,human,done,failed,logs}

# The stub. A driver leg claims the work is finished; a verify leg would pass
# it. Both are claims, and the belt takes neither.
cat > "$CONVEYOR_CLAUDE" <<'SEAT'
#!/usr/bin/env bash
# Answers the way the claude CLI does under --output-format stream-json,
# which is what the belt asks a claude seat for.
emit() { jq -nc --arg t "$1" '{type: "result", subtype: "success", result: $t}'; }
if printf '%s' "$*" | grep -q 'CONVEYOR VERIFIER'; then
    emit "I read the task and it looks complete to me.
VERDICT: pass"
else
    emit "Done - I have handled all three checklist items.
RESULT: done"
fi
SEAT
chmod +x "$CONVEYOR_CLAUDE"

cp "$HERE/dead-end-demo.md" "$CONVEYOR_ROOT/queue/dead-end-demo.md"

echo "=============================================================="
echo " a seat that always claims success, against a task that cannot"
echo " be finished. watch where the task ends up."
echo "=============================================================="

# One task moves per run, so drive it until it settles. The ceiling is the
# belt's own backstop; this loop just needs to outlast the stop rule.
for i in $(seq 1 6); do
  printf '\n----- belt run %s -----\n' "$i"
  bash "$PKG/conveyor-run.sh" 2>&1 | sed 's/^/  /'
  if find "$CONVEYOR_ROOT/failed" -name '*.md' | grep -q .; then
    echo "  -> task landed in failed/ after $i run(s)"
    break
  fi
done

settled="$(find "$CONVEYOR_ROOT/failed" -name '*.md' | head -1)"
if [ -z "$settled" ]; then
  echo
  echo "DEMO DID NOT REACH A DEAD END — that is itself a finding; the stop rule"
  echo "should have fired. Task is wherever the belt last left it:"
  find "$CONVEYOR_ROOT" -name '*.md' | sed 's/^/  /'
  exit 1
fi

echo
echo "=============================================================="
echo " THE WALK-BACK — $(basename "$settled") as the belt left it"
echo "=============================================================="
cat "$settled"

echo
echo "=============================================================="
echo " and the loss was surfaced, not swallowed:"
echo "=============================================================="
echo "--- logs/dead-ends.jsonl ---"
cat "$CONVEYOR_ROOT/logs/dead-ends.jsonl" 2>/dev/null || echo "(none)"
echo "--- logs/notify.log ---"
cat "$CONVEYOR_ROOT/logs/notify.log" 2>/dev/null || echo "(none)"
# The fourth channel, and the one that proves the no-network claim in this
# script's header: on the author's box a dead end also POSTs a card to a
# dashboard queue. Under standalone that same call appends here instead and
# touches nothing off this machine.
echo "--- logs/human-inbox.jsonl ---"
cat "$CONVEYOR_ROOT/logs/human-inbox.jsonl" 2>/dev/null || echo "(none)"

echo
echo "The seat said RESULT: done on every leg. Nothing was filed as done."
