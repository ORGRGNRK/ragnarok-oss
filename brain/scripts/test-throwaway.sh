#!/usr/bin/env bash
# brain/scripts/test-throwaway.sh -- proves the brain works, on a THROWAWAY data stack:
#   its own docker project, fresh generated logins (kept in a temp folder, never printed), its own
#   empty database, then deletes it all (containers, volume, the images it built, .work/, .venv/).
# Steps: start data/'s Postgres (pgvector) -> apply schema incl. db/brain.sql -> brain unit tests ->
#   fixloop doctor -> fix-memory demo (seed, heal run 1, run 2 must REUSE a stored fix) ->
#   receipts verify (kit_verify) -> the connector's brain_* tools (tools + access_log receipts) -> tear down.
# Needs Ollama with qwen2.5-coder:7b (the default; FIXLOOP_CODER_MODEL picks another) + nomic-embed-text
# on this machine or the LAN:
#   FIXLOOP_OLLAMA_HOST=http://alexus.local:11434 brain/scripts/test-throwaway.sh
# Options (env): TEST_PROJECT (default ragnarok-brain-test), TEST_POSTGRES_PORT (default 0 = OS picks),
#   DEMO_ATTEMPTS (default 2; a small model sometimes gives up), KEEP=1 (leave the stack running).
set -uo pipefail
BRAIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$BRAIN/../data/scripts/lib.sh"
proj="${TEST_PROJECT:-ragnarok-brain-test}"
export COMPOSE_PROJECT_NAME="$proj"
TMPD="$(mktemp -d)"; chmod 700 "$TMPD"
export KIT_ENV_FILE="$TMPD/env"
FM="$BRAIN/fix-memory"
export FIXLOOP_RUNNER_IMAGE="${proj}-runner:local"
export FIXLOOP_ENV_FILE=/dev/null   # ignore any personal brain/fix-memory/.env during the test

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: '$proj' left running; settings in $KIT_ENV_FILE"; return; fi
  dc --profile ui --profile test down -v --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${proj}-mcp:local" "$FIXLOOP_RUNNER_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TMPD" "$FM/.work" "$FM/.venv"
  say "cleaned up $proj (containers, volume, images, .work, .venv)"
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

bold "brain self-test (throwaway project: $proj)"
dc build mcp >/dev/null 2>&1 || die "building the kit image failed"
dc up -d postgres >/dev/null 2>&1 || die "could not start postgres"
wait_pg
apply_schema
pgport="$(dc port postgres 5432 | head -1 | sed 's/.*://')"
# fixloop gets the AI's read/write login by environment (never printed)
export FIXLOOP_PG_HOST=127.0.0.1 FIXLOOP_PG_PORT="$pgport" FIXLOOP_PG_DB="$POSTGRES_DB" \
       FIXLOOP_PG_USER="$MCP_DB_USER" FIXLOOP_PG_PASSWORD="$MCP_DB_PASSWORD"
say "postgres (pgvector) on 127.0.0.1:$pgport; ollama: ${FIXLOOP_OLLAMA_HOST:-http://127.0.0.1:11434}"

say ""; say "== 1. brain unit tests (cartridges, lookup, router; offline)"
python3 -m unittest discover -s "$BRAIN/tests" 2>&1 | tail -3
python3 -m unittest discover -s "$BRAIN/tests" >/dev/null 2>&1 && ok "brain unit tests" || bad "brain unit tests"

say ""; say "== 2. fix-memory setup + doctor"
docker build -q -t "$FIXLOOP_RUNNER_IMAGE" "$FM/runner" >/dev/null && ok "runner image built" || bad "runner image build"
(cd "$FM" && uv sync -q) && ok "python env ready" || bad "uv sync"
(cd "$FM" && uv run python -m unittest discover -s tests 2>&1 | tail -1)
(cd "$FM" && uv run python -m unittest discover -s tests >/dev/null 2>&1) && ok "fix-memory unit tests (offline)" || bad "fix-memory unit tests"
(cd "$FM" && uv run fixloop doctor) && ok "fixloop doctor" || bad "fixloop doctor"

say ""; say "== 3. fix-memory demo (heal, then reuse a stored fix)"
attempt=1; demo=1
while [ $attempt -le "${DEMO_ATTEMPTS:-2}" ]; do
  say "-- demo attempt $attempt"
  "$FM/scripts/demo.sh"; demo=$?
  [ $demo -eq 0 ] && break
  attempt=$((attempt+1))
done
[ $demo -eq 0 ] && ok "demo: run 1 healed, run 2 reused a stored fix, receipts verify (attempt $((attempt>${DEMO_ATTEMPTS:-2}?attempt-1:attempt)))" \
               || bad "demo did not heal and reuse within ${DEMO_ATTEMPTS:-2} attempt(s)"

say ""; say "== 4. receipts"
(cd "$FM" && uv run fixloop verify) && ok "kit_verify: write_log and access_log chains intact" || bad "receipt chains broken"
n="$(admin_psql -q -t -A -c "SELECT count(*) FROM write_log WHERE table_name IN ('brain_fixes','brain_fix_events') AND actor='fixloop'")"
[ "${n:-0}" -ge 4 ] && ok "$n brain receipts in write_log, actor=fixloop" || bad "expected >=4 brain receipts, got $n"
n="$(admin_psql -q -t -A -c "SELECT count(*) FROM brain.brain_fix_events WHERE kind='fix_reused'")"
[ "${n:-0}" -ge 1 ] && ok "fix_reused events recorded: $n" || bad "no fix_reused event"
r="$(admin_psql -q -t -A -c "SELECT count(*) FROM brain.brain_fixes WHERE source='loop' AND detail->>'embed_model_reported' IS NOT NULL AND jsonb_array_length(detail->'coder_model_reported') > 0")"
[ "${r:-0}" -ge 1 ] && ok "the healed fix's receipt names the models Ollama reported (embed + coder): $(admin_psql -q -t -A -c "SELECT detail->>'embed_model_reported' || ' / ' || (detail->'coder_model_reported')::text FROM brain.brain_fixes WHERE source='loop' ORDER BY id DESC LIMIT 1")" \
  || bad "no model_reported on the healed fix"
old="$(admin_psql -q -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_name='receipts'")"
[ "$old" = 0 ] && ok "no separate fix-memory receipts table (one receipt chain)" || bad "a separate receipts table exists"

say ""; say "== 5. brain_* tools in the connector (the ONE MCP server; fixloop-mcp was merged into it)"
dc run --rm --no-deps -T -e BRAIN_OLLAMA_URL="${FIXLOOP_OLLAMA_HOST:-http://host.docker.internal:11434}" mcp node dist/test/brain-smoke.js 2> >(grep -v " Container " >&2) \
  && ok "connector brain tools answer; search finds the demo's stored fix; receipts verify" || bad "connector brain_* smoke test"
n="$(admin_psql -q -t -A -c "SELECT count(*) FROM access_log WHERE via LIKE 'stdio:%' AND actor='brain_smoke' AND tool LIKE 'brain_%' AND ok")"
[ "${n:-0}" -ge 2 ] && ok "$n access_log receipts for the connector's brain_* calls" || bad "brain_* calls were not receipted ($n)"
m="$(admin_psql -q -t -A -c "SELECT model_reported FROM access_log WHERE actor='brain_smoke' AND tool='brain_search_fixes' AND ok AND receipt_v = 2 AND model_claimed IS NULL ORDER BY seq DESC LIMIT 1")"
[ -n "$m" ] && ok "the search receipt records the model Ollama reported (model_reported=$m), apart from any claim" || bad "brain_search_fixes receipt has no model_reported"
(cd "$FM" && uv run fixloop verify) >/dev/null && ok "chains still intact after MCP calls" || bad "chains broken after MCP calls"

say ""
if [ $fails -eq 0 ]; then bold "ALL BRAIN TESTS PASSED"; exit 0; fi
bold "SOME BRAIN TESTS FAILED ($fails); see FAIL lines above"; exit 1
