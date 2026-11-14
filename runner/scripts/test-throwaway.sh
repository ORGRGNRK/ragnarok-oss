#!/usr/bin/env bash
# runner/scripts/test-throwaway.sh -- proves the runner on a THROWAWAY stack, local models only:
#   its own docker project + fresh generated logins (temp folder, never printed), its own trays and
#   work folder (temp), then deletes it all (containers, volume, network, images, temp folders).
# Steps: 1 the upstream conveyor tests + the review-gate test, inside the belt image, no network ->
#   2 data/'s Postgres + schema incl. db/runner.sql -> 3 the box's walls (./belt probe) ->
#   4 a real task on the belt with the local model -> it must stop at "Result proposed" ->
#   only a person at a terminal can accept it -> 5 a --plan task must stop at "Plan proposed" ->
#   6 receipts in data/'s chain (AI rows are proposals, only the person's rows are not).
# Needs Ollama with qwen2.5-coder:7b and llama3.2:3b on the LAN (RUNNER_OLLAMA_HOST, default alexus).
# Options (env): TEST_PROJECT (default ragnarok-runner-test), TEST_POSTGRES_PORT (default 0 = OS picks),
#   TEST_DOOR_PORT (default 58191), DRIVE_ATTEMPTS (default 3; a 7B model sometimes stops early),
#   KEEP=1 (leave it all).
# Note: the "person" here is this script typing yes into a pseudo-terminal (macOS 'script'). That is
# the honest limit of a TTY check: it stops pipes and AI tool calls, not someone with a full shell.
set -uo pipefail
RUN="$(cd "$(dirname "$0")/.." && pwd)"
. "$RUN/../data/scripts/lib.sh"
proj="${TEST_PROJECT:-ragnarok-runner-test}"
export COMPOSE_PROJECT_NAME="$proj"
TMPD="$(mktemp -d)"; chmod 700 "$TMPD"
export KIT_ENV_FILE="$TMPD/env"
export RUNNER_ENV_FILE=/dev/null RUNNER_PROJECT="$proj" RUNNER_IMAGE="$proj-belt:local" \
       RUNNER_BELT_DIR="$TMPD/belt" RUNNER_WORK_DIR="$TMPD/work" RUNNER_DOOR_PORT="${TEST_DOOR_PORT:-58191}" \
       RUNNER_HUMAN=test-person RUNNER_TASK_TIMEOUT=900 \
       RUNNER_CODER_MODEL="${RUNNER_CODER_MODEL:-qwen2.5-coder:7b}" RUNNER_PLANNER_MODEL="${RUNNER_PLANNER_MODEL:-qwen2.5-coder:7b}" \
       RUNNER_CRITIC_MODEL="${RUNNER_CRITIC_MODEL:-llama3.2:3b}"
BELT="$RUN/ragnarok/belt"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: '$proj' left running; trays in $TMPD/belt"; return; fi
  docker rm -f "$proj-gw" "$proj-leg" >/dev/null 2>&1; docker network rm "$proj-net" >/dev/null 2>&1
  pkill -f "model-door.py --upstream .* --port $RUNNER_DOOR_PORT" 2>/dev/null
  dc --profile ui --profile test down -v --remove-orphans >/dev/null 2>&1 || true
  docker image rm "$RUNNER_IMAGE" "${proj}-mcp:local" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
  say "cleaned up $proj (containers, volume, network, image, trays, work folder)"
}
trap cleanup EXIT

make_env "$ROOT/.env.example" "$KIT_ENV_FILE" "$proj"
grep -v -e '^POSTGRES_PORT=' -e '^MCP_PORT=' -e '^NOCODB_PORT=' "$KIT_ENV_FILE" > "$KIT_ENV_FILE.tmp"
{ echo "POSTGRES_PORT=${TEST_POSTGRES_PORT:-0}"; echo "MCP_PORT=0"; echo "NOCODB_PORT=0"; } >> "$KIT_ENV_FILE.tmp"
mv "$KIT_ENV_FILE.tmp" "$KIT_ENV_FILE"; chmod 600 "$KIT_ENV_FILE"
load_env

fails=0
ok()  { say "  PASS  $*"; }
bad() { say "  FAIL  $*"; fails=$((fails+1)); }
q()   { admin_psql -q -t -A -c "$1"; }
# a "person" at a terminal: the answer is typed after the question is up (macOS 'script' sends EOF
# as soon as its input ends, so an answer piped in at once can arrive as an empty line)
person() { ( sleep 2; printf '%s\n' "$1"; sleep 1 ) | script -q /dev/null "$BELT" "$2" "$3" 2>&1; }
where() { ls "$RUNNER_BELT_DIR"/*/"$1" 2>/dev/null | sed "s#$RUNNER_BELT_DIR/##; s#/.*##"; }

bold "runner self-test (throwaway project: $proj)"
"$BELT" build || die "belt image build failed"

say ""; say "== 1. conveyor tests inside the belt image (no network; the image's belt settings cleared = upstream behaviour)"
upstream() { docker run --rm --cpus=2 --memory=2g --network none "$RUNNER_IMAGE" env -u CONVEYOR_STANDALONE -u CONVEYOR_REVIEW_GATE -u CONVEYOR_ROOT "$@"; }
for t in blocked-human files grok-seat json-tasks local-api plan portable review-gate; do
  out="$(upstream bash /opt/conveyor/tests/$t.sh 2>&1)"; rc=$?
  last="$(printf '%s\n' "$out" | grep -E '[0-9]+/[0-9]+|passed|PASS' | tail -1)"
  [ $rc -eq 0 ] && ok "$t: $last" || { bad "$t (exit $rc)"; printf '%s\n' "$out" | tail -15; }
done
out="$(upstream python3 /opt/conveyor/tests/test_taskjson.py 2>&1)"
[ $? -eq 0 ] && ok "test_taskjson.py: $(printf '%s\n' "$out" | grep -E '^Ran ' )" || { bad "test_taskjson.py"; printf '%s\n' "$out" | tail -10; }

say ""; say "== 2. data layer"
dc up -d postgres >/dev/null 2>&1 || die "could not start postgres"
wait_pg
apply_schema
"$BELT" doctor && ok "./belt doctor" || bad "./belt doctor"

say ""; say "== 3. the box's walls"
"$BELT" probe && ok "./belt probe" || bad "./belt probe"

say ""; say "== 4. a real task, local model ($RUNNER_CODER_MODEL)"
a=1; t1=""
while [ $a -le "${DRIVE_ATTEMPTS:-3}" ]; do
  rm -f "$RUNNER_WORK_DIR/hello.txt"
  printf '%s\n' "Create the file /work/hello.txt containing exactly one line: hello from the belt" "" \
    "## Checklist" "- [ ] /work/hello.txt says hello from the belt :: verify: grep -qx 'hello from the belt' /work/hello.txt" \
    | "$BELT" add "belt hello $a" >/dev/null || bad "add"
  t1="$(ls "$RUNNER_BELT_DIR/queue" | grep "belt-hello-$a" | head -1)"
  say "  attempt $a, task: $t1"
  start=$(date +%s); "$BELT" run --max 6; say "  (belt ran $(( $(date +%s) - start ))s; it ended in $(where "$t1")/)"
  [ "$(where "$t1")" = human ] && break
  say "  INFO  attempt $a: the local model did not finish (see the belt summary above)"
  a=$((a+1))
done
[ $a -le "${DRIVE_ATTEMPTS:-3}" ] && ok "the local model did the task (attempt $a of ${DRIVE_ATTEMPTS:-3})" || bad "the local model did not finish the task in ${DRIVE_ATTEMPTS:-3} attempt(s)"
[ "$(where "$t1")" = human ] && grep -q '^## Result proposed' "$RUNNER_BELT_DIR/human/$t1" \
  && ok "the model's work stopped at 'Result proposed' in human/ (not done/)" || bad "expected human/ + Result proposed, it is in '$(where "$t1")'"
grep -qx 'hello from the belt' "$RUNNER_WORK_DIR/hello.txt" 2>/dev/null && ok "the work exists: hello.txt (written inside the box)" || bad "hello.txt missing or wrong"
[ -z "$(ls "$RUNNER_BELT_DIR/done")" ] && ok "done/ is empty before a person says yes" || bad "something reached done/ on its own"
out="$("$BELT" accept "$t1" < /dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ "$(where "$t1")" = human ] && ok "accept from a script/pipe is refused (not a TTY)" || bad "non-TTY accept: exit $rc $out"
out="$(printf 'yes\n' | "$BELT" accept "$t1" 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ "$(where "$t1")" = human ] && ok "piping 'yes' is refused too" || bad "piped yes: exit $rc $out"
out="$(person no accept "$t1")"
[ "$(where "$t1")" = human ] && case "$out" in *"Type yes"*"not done"*) true;; *) false;; esac \
  && ok "at a terminal, answering 'no' leaves it waiting" || bad "answer no: $out"
out="$(person yes accept "$t1")"
[ "$(where "$t1")" = done ] && grep -q '^## Accepted by test-person' "$RUNNER_BELT_DIR/done/$t1" \
  && ok "at a terminal, typing yes -> done/ ($(printf '%s' "$out" | grep -o 'receipt #[0-9]* [0-9a-f]*'))" || bad "accept yes: $out"

say ""; say "== 5. a --plan task (planner ${RUNNER_PLANNER_MODEL:-qwen2.5-coder:7b}, critic ${RUNNER_CRITIC_MODEL:-llama3.2:3b})"
"$BELT" add "belt plan" --plan -m "Create /work/plan.txt containing exactly one line: planned work. The check: grep -qx 'planned work' /work/plan.txt" >/dev/null \
  && ok "plan task added" || bad "add --plan"
t2="$(ls "$RUNNER_BELT_DIR/plan" | grep 'belt-plan' | head -1)"
say "  task: $t2"
start=$(date +%s); "$BELT" run --max 4; say "  (belt ran $(( $(date +%s) - start ))s)"
w="$(where "$t2")"
[ ! -e "$RUNNER_WORK_DIR/plan.txt" ] && ok "nothing was built before a person approved the plan" || bad "plan.txt exists before approval"
[ "$w" != queue ] && [ "$w" != done ] && [ "$w" != running ] && ok "the plan did not go to work on its own (it is in $w/)" || bad "plan went to $w/ on its own"
if [ "$w" = human ] && grep -q '^## Plan proposed' "$RUNNER_BELT_DIR/human/$t2"; then
  ok "critic passed it -> 'Plan proposed', waiting for a person"
  out="$("$BELT" approve "$t2" < /dev/null 2>&1)"; [ "$(where "$t2")" = human ] && ok "approve from a script is refused" || bad "non-TTY approve moved it"
  out="$(person yes approve "$t2")"
  [ "$(where "$t2")" = queue ] && ok "a person approved at a terminal -> queue/" || bad "approve: $out"
  "$BELT" run --max 6
  w="$(where "$t2")"
  if [ "$w" = human ] && grep -q '^## Result proposed' "$RUNNER_BELT_DIR/human/$t2"; then
    ok "the approved plan ran and stopped at 'Result proposed'"
    out="$(person yes accept "$t2")"; [ "$(where "$t2")" = done ] && ok "accepted -> done/" || bad "accept 2: $out"
  else
    say "  INFO  the approved plan ended in $w/ (the local model did not finish it); rejecting it"
    [ "$w" = human ] && person yes reject "$t2" >/dev/null
  fi
else
  say "  INFO  the critic/planner did not pass the plan (it is in $w/); that is a 'no', not a failure of the gate"
  [ "$w" = human ] && { out="$(person yes reject "$t2")"; [ "$(where "$t2")" = failed ] && ok "a person rejected it -> failed/" || bad "reject: $out"; }
fi

say ""; say "== 6. receipts in data/'s chain"
"$BELT" ingest | grep -q ': 0 new' && ok "re-copying receipts adds nothing (each line once)" || bad "ingest not idempotent"
n_ai="$(q "SELECT count(*) FROM runner.runner_events WHERE actor LIKE 'runner:%' AND proposal")"
n_p="$(q "SELECT count(*) FROM runner.runner_events WHERE actor LIKE 'human:%' AND NOT proposal")"
n_bad="$(q "SELECT count(*) FROM runner.runner_events WHERE (actor LIKE 'human:%') = proposal")"
[ "${n_ai:-0}" -ge 2 ] && ok "$n_ai belt legs receipted as AI proposals" || bad "expected belt receipts, got $n_ai"
[ "${n_p:-0}" -ge 1 ] && [ "$n_bad" = 0 ] && ok "$n_p person decisions (proposal = false); every other row is a proposal" || bad "person rows $n_p, mismatched $n_bad"
n_w="$(q "SELECT count(*) FROM write_log WHERE table_name='runner_events' AND action='INSERT'")"
n_e="$(q "SELECT count(*) FROM runner.runner_events")"
[ "$n_w" = "$n_e" ] && ok "every runner row has its write_log receipt ($n_w)" || bad "write_log $n_w vs rows $n_e"
n_h="$(q "SELECT count(*) FROM write_log WHERE table_name='runner_events' AND actor LIKE 'human:test-person'")"
[ "$n_h" = "$n_p" ] && ok "the person's receipts carry their name (human:test-person)" || bad "human receipts $n_h vs $n_p"
n_m="$(q "SELECT count(*) FROM runner.runner_events WHERE seat <> 'runner' AND model_reported IS NOT NULL")"
ex_m="$(q "SELECT seat || ': configured ' || coalesce(model, '?') || ', API reported ' || model_reported FROM runner.runner_events WHERE model_reported IS NOT NULL ORDER BY id LIMIT 1")"
[ "${n_m:-0}" -ge 1 ] && ok "$n_m belt legs record the model the API reported, apart from the configured one ($ex_m)" || bad "no runner row has model_reported"
n_rm="$(q "SELECT count(*) FROM runner.runner_events WHERE seat = 'runner' AND model_reported IS NOT NULL")"
[ "$n_rm" = 0 ] && ok "rows where no model ran (seat runner) have model_reported NULL" || bad "$n_rm runner-seat rows claim a model"
n_d="$(grep -c ' -> 200 reported=' "$RUNNER_BELT_DIR/logs/model-door.log" 2>/dev/null)"
[ "${n_d:-0}" -ge 1 ] && ok "the model door (on the Mac, outside the box) logged the reported model for $n_d answers" || bad "model-door.log has no reported= lines"
"$BELT" verify | grep -v INTACT && bad "a receipt chain is broken" || ok "kit_verify: chains intact"
dc exec -T postgres psql -U "$MCP_DB_USER" -d "$POSTGRES_DB" -X -c "UPDATE runner.runner_events SET verdict='x'" >/dev/null 2>&1 \
  && bad "the AI login could edit belt receipts" || ok "the AI login cannot edit belt receipts"
"$BELT" receipts 8

say ""
[ $fails -eq 0 ] && bold "ALL PASS" || bold "$fails FAILED"
exit $fails
