#!/usr/bin/env bash
# json-tasks.sh — the JSON plan path (branch json-tasks), proven with stub seats.
# NO MODEL IS CALLED: claude and grok below are one small Python script that
# answers the way the CLIs' stream-json does, choosing its answer from the
# prompt (which seat it is asked to be) and a SCENARIO word in the task. Every
# scenario drives the real conveyor-run.sh against a throwaway belt root in
# TMPDIR, one leg per call. The live belt is never touched.
#
# ASSERTION COUNT IS ASSERTED, as in plan.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=48
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

S="$(mktemp -d "${TMPDIR:-/tmp}/json-tasks-test.XXXXXX")"; trap '[ -n "${KEEP:-}" ] || rm -rf "$S"' EXIT
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/bin" "$FAKEHOME/.grok/bin"
STUB="$FAKEHOME/bin/claude"
cat > "$STUB" <<'SEAT'
#!/usr/bin/env python3
# Stub seat. Logs "<name> <role> <scenario> <round> <attempt> <native> <told>" per call.
import json, os, re, subprocess, sys
me = os.path.basename(sys.argv[0]); args = sys.argv[1:]
prompt = args[args.index("-p") + 1] if "-p" in args else ""
native = "--json-schema" in args
g = lambda rx, d="-": (re.search(rx, prompt, re.M) or [None, d])[1]
scn, root = g(r"SCENARIO=([a-z0-9]+)"), g(r"ROOT=(\S+)")
rnd, att = g(r"^ROUND: (\d+)"), g(r"attempt (\d+) of")
told = "told" if "REJECTED BY THE VALIDATOR" in prompt or "ISSUE: " in prompt else "-"
role = "executor"
if "CONVEYOR PLANNER SEAT (JSON)" in prompt: role = "planner"
elif "CONVEYOR CRITIC SEAT (JSON)" in prompt: role = "critic"
elif "CONVEYOR VERIFIER" in prompt: role = "verifier"
with open(os.environ["STUB_LOG"], "a") as f:
    f.write("%s %s %s %s %s %s %s\n" % (me, role, scn, rnd, att, "native" if native else "plain", told))
if native and scn == "noflag":
    sys.stderr.write("error: unknown option '--json-schema'\n"); sys.exit(1)
if role in ("planner", "critic"):   # any edit to the task file must be undone by the belt
    run = os.path.join(os.environ["CONVEYOR_ROOT"], "running")
    for n in os.listdir(run):
        if n.endswith(".md"):
            open(os.path.join(run, n), "a").write("SEAT SCRIBBLE\n")
def say(text, obj=None):
    ev = {"type": "result", "subtype": "success", "is_error": False, "result": text}
    if obj is not None and native: ev["structured_output"] = obj
    print(json.dumps(ev))
def task(extra_check=False):
    checks = [{"claim": "hello.txt says hello", "verify": "grep -qx hello hello.txt"}]
    if extra_check:
        checks.append({"claim": "hello.txt has exactly one line", "verify": "test \"$(wc -l < hello.txt)\" -eq 1"})
    return {"schema_version": "conveyor-task/0.1", "id": "write-hello", "title": "Write hello into hello.txt",
            "goal": "hello.txt in the repo root contains the single word hello.", "project": "demo", "root": root,
            "files_to_touch": [{"path": "hello.txt", "action": "create", "why": "the deliverable"}],
            "steps": ["Create hello.txt containing the word hello and a newline."],
            "constraints": {"network": "none", "secrets": "none", "write_scope": ["hello.txt"]},
            "acceptance": {"checks": checks, "expected_result": "hello.txt holds hello."},
            "limits": {"max_files_changed": 1, "max_lines_changed": 5},
            "depends_on": [], "status": "proposed",
            "provenance": {"proposed_by": "whatever", "source": "planner", "proposed_at": "bogus"}}
if role == "planner":
    t = task(extra_check=(scn == "revise" and rnd == "2"))
    if scn == "alwaysbad" or (scn == "retry" and att == "1"):
        t["constraints"]["secrets"] = "allowed"; del t["goal"]
    if scn == "fenced":
        say("Here is the task.\n```json\n%s\n```\n" % json.dumps(t, indent=2))
    else:
        say(json.dumps(t), t)
elif role == "critic":
    if scn == "deadlock" or (scn == "revise" and rnd == "1"):
        v = {"verdict": "issues", "issues": [{"where": "acceptance.checks", "problem": "nothing checks the file has only one line", "fix": "add a line-count check"}]}
    else:
        v = {"verdict": "pass", "issues": []}
    say(json.dumps(v), v)
elif role == "verifier":
    say("CONFIRMED: hello.txt says hello\nVERDICT: pass")
else:
    if root != "-":
        open(os.path.join(root, "hello.txt"), "w").write("hello\n")
        if scn == "scope":
            open(os.path.join(root, "extra.txt"), "w").write("not allowed\n")
    say("Done.\nRESULT: done")
SEAT
chmod +x "$STUB"; cp "$STUB" "$FAKEHOME/.grok/bin/grok"

newroot() { # name -> $R (belt root) and $G (a git repo the task works in)
  R="$S/$1"; G="$S/repo-$1"
  mkdir -p "$R"/{plan,queue,running,verify,human,done,failed,logs} "$G"
  git -C "$G" init -q && printf 'seed\n' > "$G/README" && git -C "$G" add README \
    && git -C "$G" -c user.name=t -c user.email=t@t commit -qm seed
  : > "$S/stub.log"
}
belt() {
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT -u CONVEYOR_PLANNER_SEAT \
      -u CONVEYOR_CRITIC_SEAT -u CONVEYOR_ESCALATE_SEAT -u XAI_API_KEY -u CONVEYOR_JSON_NATIVE_SCHEMA \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 \
      CONVEYOR_CLAUDE="$FAKEHOME/bin/claude" CONVEYOR_GROK="$FAKEHOME/.grok/bin/grok" \
      CONVEYOR_DRIVER_SEAT=claude CONVEYOR_VERIFIER_SEAT=claude \
      STUB_LOG="$S/stub.log" "$@" bash "$RUN" >> "$R/belt.out" 2>&1
}
runs() { local n=$1 i; shift; for i in $(seq "$n"); do belt "$@"; done; }
plantask() { # name scenario
  cat > "$R/plan/$1.md" <<T
# $1

queued: 2026-10-28T01:00:00-07:00
by: test
plan-format: json

SCENARIO=$2 Want: write the word hello into hello.txt in ROOT=$G
T
}
calls() { grep -c -- "$1" "$S/stub.log"; }

echo "-- A. conveyor add --plan defaults to JSON; critic passes -> straight to queue/"
newroot approve
out=$(env CONVEYOR_ROOT="$R" bash "$PKG/conveyor" add "approve me" --plan -m "SCENARIO=approve Want: hello in ROOT=$G" 2>&1)
f=$(ls "$R"/plan/*.md 2>/dev/null | head -1); t=$(basename "${f:-x}" .md)
has "the task is marked plan-format: json" '^plan-format: json$' "${f:-/nonexistent}"
belt
at "$t" queue
has "the rendered check is live, run from the task's root" "^- \[ \] hello.txt says hello :: verify: cd $G && grep -qx hello hello.txt$" "$R/queue/$t.md"
has "the belt added the scope/size check" '^- \[ \] only files inside write_scope changed, within the size limits :: verify: python3 .*scope-check' "$R/queue/$t.md"
has "the approved block says no human approval" '^## Plan approved — round 1 \(JSON task, no human approval\)' "$R/queue/$t.md"
hasnt "GATE LIFTED: no HUMAN box anywhere in the task" ':: verify: HUMAN' "$R/queue/$t.md"
[ ! -s "$R/logs/human-inbox.jsonl" ] && ok "GATE LIFTED: nothing was filed for a person" || bad "human-inbox has: $(cat "$R/logs/human-inbox.jsonl")"
hasnt "edits the seats made to the task file were undone" 'SEAT SCRIBBLE' "$R/queue/$t.md"
has "the belt stamped status queue in the task JSON" '"status": "queue"' "$R/logs/$t.task.json"
has "the belt stamped who wrote it" '"proposed_by": "planner:claude"' "$R/logs/$t.task.json"
[ "$(calls 'claude planner')" = 1 ] && [ "$(calls 'grok critic')" = 1 ] && ok "one planner call (claude), one critic call (grok)" || bad "calls: $(cat "$S/stub.log")"
[ "$(calls 'planner approve 1 1 native')" = 1 ] && ok "the planner was asked with --json-schema" || bad "calls: $(cat "$S/stub.log")"
has "a plan-approved receipt" '"verdict":"plan-approved"' "$R/logs/receipts.jsonl"

echo "-- B. invalid JSON goes back to the planner with the errors, same round"
newroot retry; plantask t-retry retry
belt
at t-retry queue
[ "$(calls 'planner retry 1 2 native told')" = 1 ] && ok "attempt 2 was told why attempt 1 was rejected" || bad "calls: $(cat "$S/stub.log")"
has "the errors are in the attempt-1 transcript" 'must be .none.' "$(ls "$R"/logs/t-retry.plan.*[0-9].try1.log | head -1)"
has "the note says it was valid on attempt 2" 'valid on attempt 2' "$R/queue/t-retry.md"

echo "-- C. JSON that never validates: bounded retries, critic never spent"
newroot bad; plantask t-bad alwaysbad
belt
at t-bad plan
[ "$(calls 'claude planner')" = 3 ] && ok "1 try + 2 retries, then it stopped" || bad "planner calls: $(calls 'claude planner')"
[ "$(calls 'critic')" = 0 ] && ok "the critic was not called on invalid JSON" || bad "critic called"
has "the rejection names the validator errors" 'REJECTED by the validator after 3 attempt' "$R/plan/t-bad.md"
hasnt "no live checklist from a rejected plan" '^- \[ \] ' "$R/plan/t-bad.md"
has "a plan-rejected receipt" '"verdict":"plan-rejected"' "$R/logs/receipts.jsonl"

echo "-- D. critic lists issues, planner revises, critic passes"
newroot revise; plantask t-revise revise
belt
at t-revise plan
has "round 1 issues are in the task" 'ISSUE: acceptance.checks: nothing checks the file has only one line \(fix: add a line-count check\)' "$R/plan/t-revise.md"
belt
at t-revise queue
[ "$(calls 'planner revise 2 1 native told')" = 1 ] && ok "the round-2 planner saw the issues" || bad "calls: $(cat "$S/stub.log")"
has "the revised check is live" '^- \[ \] hello.txt has exactly one line :: verify: cd ' "$R/queue/t-revise.md"

echo "-- E. never passes: bounded rounds, then human/ (disagreement, not an approval gate)"
newroot deadlock; plantask t-dead deadlock
runs 2
at t-dead human
[ "$(calls 'grok critic')" = 2 ] && ok "exactly 2 critic rounds" || bad "critic calls: $(calls 'grok critic')"
has "the accept-anyway box carries the rendered checks" '^- \[ \] hello.txt says hello :: verify: cd ' "$R/human/t-dead.md"

echo "-- F. happy path: plan -> queue -> coder -> checks -> verify -> done/"
newroot happy; plantask t-happy happy
runs 4
at t-happy done
[ "$(cat "$G/hello.txt" 2>/dev/null)" = hello ] && ok "the work was actually done" || bad "hello.txt missing"
has "the task's own test command ran and passed" '\[x\] PASS  hello.txt says hello' "$(grep -l 'PASS  hello.txt says hello' "$R"/logs/*.log | head -1)"
has "the scope check ran and passed" '\[x\] PASS  only files inside write_scope changed' "$(grep -l 'PASS  only files inside' "$R"/logs/*.log | head -1)"
[ "$(calls 'executor happy')" = 1 ] && [ "$(calls 'verifier happy')" = 1 ] && ok "one coder leg, one verify leg" || bad "calls: $(cat "$S/stub.log")"

echo "-- G. a coder that writes outside write_scope is not filed as done"
newroot scope; plantask t-scope scope
runs 3
[ ! -f "$R/done/t-scope.md" ] && ok "not in done/" || bad "t-scope reached done/"
grep -rq 'FAIL  only files inside write_scope changed' "$R"/logs/*.log && ok "the scope check named the failure" || bad "no scope FAIL in logs"
has "the coder is told how to see what is out of scope" 'run its verify command yourself' "$R/queue/t-scope.md"
python3 "$PKG/conveyor-taskjson" scope-check "$R/logs/t-scope.task.json" > "$S/scope.out" 2>&1
has "and that command names the stray file" 'changed outside write_scope: extra.txt' "$S/scope.out"

echo "-- H. structured output: off switch, fallback, and prose with a fenced block"
newroot nonative; plantask t-nn approve
belt CONVEYOR_JSON_NATIVE_SCHEMA=0
at t-nn queue
[ "$(calls 'planner approve 1 1 plain')" = 1 ] && ok "CONVEYOR_JSON_NATIVE_SCHEMA=0 sends no --json-schema" || bad "calls: $(cat "$S/stub.log")"
newroot noflag; plantask t-nf noflag
belt
at t-nf queue
[ "$(calls 'planner noflag 1 1 native')" = 1 ] && [ "$(calls 'planner noflag 1 1 plain')" = 1 ] \
  && ok "a CLI that refuses --json-schema is asked again without it" || bad "calls: $(cat "$S/stub.log")"
newroot fenced; plantask t-fenced fenced
belt CONVEYOR_JSON_NATIVE_SCHEMA=0
at t-fenced queue

echo "-- I. old tasks keep working"
newroot old
cat > "$R/queue/t-old.md" <<T
# t-old

SCENARIO=old ROOT=$G

## Checklist
- [ ] hello.txt says hello :: verify: grep -qx hello $G/hello.txt
T
runs 3
at t-old done
cat > "$R/plan/t-mdplan.md" <<T
# t-mdplan

SCENARIO=md Want: something (no plan-format line: the markdown planner)
T
belt
grep -q ' md ' "$S/stub.log" && ok "a plan/ task without the header still gets a plan leg" || bad "no call for t-mdplan"
hasnt "no JSON planner prompt was used for it" 'planner md' "$S/stub.log"

RAN=$((PASS+FAIL))
printf '\njson-tasks.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
