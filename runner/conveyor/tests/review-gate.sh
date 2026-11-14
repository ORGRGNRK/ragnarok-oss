#!/usr/bin/env bash
# review-gate.sh — Ragnarok's review gate (CONVEYOR_REVIEW_GATE=1): AI outputs are
# proposals, nothing is auto-approved. Same stub seats as json-tasks.sh (copied
# below): NO MODEL IS CALLED, the real conveyor-run.sh runs against a throwaway
# belt root in TMPDIR, one leg per call.
#   A. a JSON plan the critic passes waits in human/ with an unticked approve box
#   B. a person's tick + move to queue/ -> built -> checks + verifier pass ->
#      human/ as "Result proposed", NOT done/
#   C. an ordinary checklist task: verifier pass -> human/, never done/
#   D. a seat that ticks the approve box itself is undone (still waits on a person)
# ASSERTION COUNT IS ASSERTED, as in plan.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=19
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
    if os.environ.get("STUB_PRE"):
        subprocess.run(["bash", os.environ["STUB_PRE"]])
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
gate() { belt CONVEYOR_REVIEW_GATE=1 "$@"; }
last_verdict() { tail -1 "$R/logs/receipts.jsonl" | jq -r .verdict; }

echo "-- A. JSON plan, critic passes -> human/ (a proposal), not queue/"
newroot gateplan; plantask g-a approve
gate
at g-a human
has "the plan is marked a proposal" '^## Plan proposed — round 1 \(waiting for your yes\)' "$R/human/g-a.md"
has "with an UNTICKED approve box first in the live checklist" '^- \[ \] you approve this plan before any work runs :: verify: HUMAN$' "$R/human/g-a.md"
[ "$(last_verdict)" = plan-proposed ] && ok "receipt verdict is plan-proposed" || bad "receipt verdict: $(last_verdict)"
has "a person was asked" '"itemRef":"conveyor:g-a\.md:plan"' "$R/logs/human-inbox.jsonl"
gate
at g-a human
[ "$(calls ' executor ')" = 0 ] && ok "nothing was built while the plan waits" || bad "executor ran $(calls ' executor ') time(s)"

echo "-- B. a person approves -> built -> checks + verifier pass -> Result proposed in human/, not done/"
sed -i 's/^- \[ \] you approve this plan before any work runs :: verify: HUMAN$/- [x] you approve this plan before any work runs :: verify: HUMAN/' "$R/human/g-a.md"
mv "$R/human/g-a.md" "$R/queue/g-a.md"
gate; at g-a verify
gate; at g-a human
[ "$(last_verdict)" = verify-pass-proposed ] && ok "receipt verdict is verify-pass-proposed" || bad "receipt verdict: $(last_verdict)"
has "the result is marked a proposal" '^## Result proposed \(waiting for your yes\)' "$R/human/g-a.md"
[ -z "$(ls "$R/done")" ] && ok "done/ is empty: only a person files done" || bad "done/ has: $(ls "$R/done")"
has "a person was asked to accept" '"itemRef":"conveyor:g-a\.md:accept"' "$R/logs/human-inbox.jsonl"

echo "-- C. ordinary checklist task: verifier pass -> human/, never done/"
newroot gateplain
cat > "$R/queue/g-c.md" <<EOF
# g-c

SCENARIO=plain Want: hello in ROOT=$G

## Checklist
- [ ] hello.txt says hello :: verify: cd $G && grep -qx hello hello.txt
EOF
gate; at g-c verify
gate; at g-c human
[ -z "$(ls "$R/done")" ] && ok "done/ is empty" || bad "done/ has: $(ls "$R/done")"

echo "-- D. a seat ticking the approve box is undone"
newroot gateforge
cat > "$R/queue/g-d.md" <<EOF
# g-d

SCENARIO=forge Want: hello in ROOT=$G

## Checklist
- [ ] you approve this plan before any work runs :: verify: HUMAN
- [ ] hello.txt says hello :: verify: cd $G && grep -qx hello hello.txt
EOF
cat > "$FAKEHOME/forge.sh" <<'F'
for f in "$CONVEYOR_ROOT"/running/*.md; do sed -i 's/^- \[ \] you approve/- [x] you approve/' "$f"; done
F
STUB_PRE="$FAKEHOME/forge.sh" gate
at g-d human
has "the approve box is unticked again" '^- \[ \] you approve this plan before any work runs :: verify: HUMAN$' "$R/human/g-d.md"
has "and the forgery is on the record" 'hand-ticks erased: .*HUMAN step.*forgery' "$R/human/g-d.md"

echo
echo "review-gate.sh: $PASS passed, $FAIL failed ($((PASS+FAIL))/$EXPECTED assertions ran)"
[ "$FAIL" -eq 0 ] && [ $((PASS+FAIL)) -eq "$EXPECTED" ]
