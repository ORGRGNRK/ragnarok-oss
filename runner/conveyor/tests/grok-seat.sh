#!/usr/bin/env bash
# grok-seat.sh — the grok seat, proven with a stub. NO MODEL IS CALLED.
#
# The stub stands where Grok Build's installer puts the real binary
# ($HOME/.grok/bin/grok, under a throwaway HOME) and answers the way
# Grok Build 1.0.70 documents `--output-format streaming-messages-json`:
# a system/init line, assistant messages with tool_use blocks, user messages
# with tool_result blocks, and a final {"type":"result","result":...}.
# It records the flags and fence variables it was started with, so this
# suite proves the runner ASKS for headless, auto-approve, stream output and
# the hook/MCP fence -- not that the real CLI honours them (that needs a real
# run, which spends the operator's usage).
#
# ASSERTION COUNT IS ASSERTED, as in portable.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=16
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qE -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (/$2/ not in $3)"; fi; }

S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/.grok/bin"
STUB="$FAKEHOME/.grok/bin/grok"
cat > "$STUB" <<'SEAT'
#!/usr/bin/env bash
# Fake Grok Build. Modes: honest (does the work), lie (claims it, does nothing),
# crash (fails the way a logged-out grok would).
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
{ printf 'ARGS:'; for a in "$@"; do [ "$a" = "$prompt" ] && a="<prompt>"; printf ' %s' "$a"; done; echo
  echo "ENV: hooks=${GROK_CLAUDE_HOOKS_ENABLED:-unset} mcps=${GROK_CLAUDE_MCPS_ENABLED:-unset} cursor_hooks=${GROK_CURSOR_HOOKS_ENABLED:-unset} cursor_mcps=${GROK_CURSOR_MCPS_ENABLED:-unset}"
} >> "$GROKSTUB_LOG"
j() { jq -nc "$@"; }
if [ "${GROKSTUB_MODE:-honest}" = crash ]; then
  j '{type:"error",message:"Not signed in: run grok login or set XAI_API_KEY"}'
  exit 1
fi
j '{type:"system",subtype:"init",session_id:"s1",model:"grok-stub",cwd:env.PWD,permissionMode:"bypassPermissions",tools:["read_file","write_file","bash"]}'
if printf '%s' "$prompt" | grep -q 'CONVEYOR VERIFIER'; then
  j '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"c1",name:"bash",input:{command:"cat the output file"}}]},session_id:"s1"}'
  j '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"c1",content:"hello",is_error:false}]},session_id:"s1"}'
  j --arg t "CONFIRMED: the output file exists — cat showed hello
VERDICT: pass" '{type:"result",subtype:"success",is_error:false,result:$t,session_id:"s1"}'
  exit 0
fi
out=$(printf '%s' "$prompt" | grep -oE 'OUTFILE=[^ ]+' | head -1 | cut -d= -f2)
if [ "${GROKSTUB_MODE:-honest}" = honest ] && [ -n "$out" ]; then
  printf 'hello\n' > "$out"
  j --arg p "$out" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Writing the file."},{type:"tool_use",id:"c1",name:"write_file",input:{path:$p,content:"hello"}}]},session_id:"s1"}'
  j '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"c1",content:"ok",is_error:false}]},session_id:"s1"}'
fi
j --arg t "I did the work.
RESULT: done — the output file exists" '{type:"result",subtype:"success",is_error:false,result:$t,session_id:"s1"}'
SEAT
chmod +x "$STUB"

newroot() { R="$S/$1"; mkdir -p "$R"/{queue,running,verify,human,done,failed,logs}; }
belt() { # extra env... ; runs one runner invocation against $R
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT -u CONVEYOR_GROK -u XAI_API_KEY \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 \
      CONVEYOR_DRIVER_SEAT=grok CONVEYOR_VERIFIER_SEAT=grok CONVEYOR_LEG_CEILING=3 \
      GROKSTUB_LOG="$S/stub.log" "$@" bash "$RUN" 2>&1
}
task() { # name outfile
  cat > "$R/queue/$1.md" <<T
# $1

Want: write the word hello into OUTFILE=$2

## Checklist
- [ ] the output file says hello :: verify: grep -qx hello $2
T
}
settle() { # extra env...; drive until the task is in done/ or failed/
  local i; for i in 1 2 3 4 5 6 7 8; do
    belt "$@" >> "$R/belt.out"
    find "$R/done" "$R/failed" -name '*.md' | grep -q . && return 0
  done; return 1
}

echo "-- A. an honest grok seat gets a task to done/"
newroot honest; task t-honest "$S/honest-out.txt"
settle GROKSTUB_MODE=honest
if [ -f "$R/done/t-honest.md" ]; then ok "task filed in done/"; else bad "task not in done/ ($(find "$R" -name '*.md'))"; fi
dlog=$(grep -l 'driver leg (grok seat)' "$R"/logs/*.log 2>/dev/null | head -1)
vlog=$(grep -l 'verifier leg (grok seat)' "$R"/logs/*.log 2>/dev/null | head -1)
[ -n "$dlog" ] && ok "a driver leg ran on the grok seat" || bad "no driver leg log names the grok seat"
[ -n "$vlog" ] && ok "a verify leg ran on the grok seat" || bad "no verifier leg log names the grok seat"
# The seat's part of the log is everything before the runner's own
# conveyor-check block; run_seat reads the verdict as its last non-blank line.
if [ -n "$dlog" ] && [ "$(awk '/^--- conveyor-check/ {exit} NF {l=$0} END {print l}' "$dlog")" = "RESULT: done — the output file exists" ]; then
  ok "driver log ends with the seat's RESULT line (verdict parsing unchanged)"
else bad "driver log's final line is not the RESULT line"; fi
if [ -n "$dlog" ] && ! grep -q '"type"' "$dlog"; then ok "no raw JSON leaked into the text log"
else bad "raw JSON in the text log (the verdict harvest would read it)"; fi
has "the stream was kept beside the log for the live view" '"subtype":"init"' "${dlog%.log}.jsonl"
has "verify log ends with VERDICT: pass" '^VERDICT: pass$' "${vlog:-/nonexistent}"

echo "-- B. what the runner asked grok for"
has "headless prompt (-p) and no update check" '^ARGS: --no-auto-update -p <prompt>' "$S/stub.log"
has "auto-approve (the seat cannot ask anyone)" '--always-approve' "$S/stub.log"
has "Claude-compatible stream output" '--output-format streaming-messages-json' "$S/stub.log"
has "Claude/Cursor hooks and MCP servers switched off" '^ENV: hooks=false mcps=false cursor_hooks=false cursor_mcps=false$' "$S/stub.log"

echo "-- C. NEGATIVE CONTROL: a grok seat that only claims success never reaches done/"
newroot lie; task t-lie "$S/lie-out.txt"
settle GROKSTUB_MODE=lie
if [ -f "$R/failed/t-lie.md" ] && [ ! -f "$R/done/t-lie.md" ]; then ok "the lying task ended in failed/, not done/"
else bad "the lying task did not dead-end ($(find "$R" -name '*.md'))"; fi

echo "-- D. a grok that cannot run is a seat crash, not a task outcome"
newroot crash; task t-crash "$S/crash-out.txt"
belt GROKSTUB_MODE=crash > "$R/belt.out"
if [ -f "$R/queue/t-crash.md" ]; then ok "task went back to queue/ untouched"; else bad "crashed task not back in queue/ ($(find "$R" -name '*.md'))"; fi
has "the crash note quotes grok's own error" 'Not signed in: run grok login or set XAI_API_KEY' "$R/queue/t-crash.md"

echo "-- E. preflight and doctor"
newroot nobin; mv "$STUB" "$S/grok.away"
belt > "$R/belt.out"; rc=$?
mv "$S/grok.away" "$STUB"
if [ "$rc" -ne 0 ] && grep -q 'grok seat selected but no binary' "$R/belt.out"; then ok "no grok binary: the belt refuses to start and says why"
else bad "missing grok binary was not caught at preflight (rc $rc)"; fi
# Doctor finds grok in ~/.grok/bin even when that is not on PATH (the Mac app's case).
env -u CONVEYOR_GROK HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_DRIVER_SEAT=grok CONVEYOR_VERIFIER_SEAT=grok \
    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$PKG/conveyor" doctor > "$R/doctor.out" 2>&1
has "doctor lists grok as an available seat" 'ok    seat available: grok' "$R/doctor.out"

RAN=$((PASS+FAIL))
printf '\ngrok-seat.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
