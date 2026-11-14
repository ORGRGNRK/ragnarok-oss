#!/usr/bin/env bash
# ./kit test -- proves the kit works, on a THROWAWAY copy of the stack:
#   separate docker project (<name>-test), its own fresh secrets, its own empty database,
#   random free ports. The client's real data, .env and containers are never touched.
# It uses this folder's client/schema.json + seed.json, so it also proves the client's schema works.
# Steps: start -> apply schema -> seed (+ FAKE business rows) -> connector unit/integration tests
# (vitest) -> run ../connector/test/e2e.ts inside the stack -> extra checks from
# outside (real HTTP port, token never in logs, ./kit verify catches the tamper) -> brain tables
# (pgvector, fix-memory receipts, AI login cannot change/delete fixes) -> runner tables
# (belt receipts; AI login cannot change/delete them) -> delete it all.
#   TEST_PROJECT=name TEST_POSTGRES_PORT=n TEST_MCP_PORT=n TEST_NOCODB_PORT=n ./kit test
#                       pick the throwaway project name / ports (default: <name>-test and OS-chosen free ports)
#   KEEP=1 ./kit test   leaves the test stack running for a look (remove later: KEEP=0 ./kit test --cleanup)
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
cd "$ROOT"

base="ragnarok-data"
if [ -f "$ROOT/.env" ]; then base="$(grep '^COMPOSE_PROJECT_NAME=' "$ROOT/.env" | cut -d= -f2)"; fi
proj="${TEST_PROJECT:-${base:-ragnarok-data}-test}"
mkdir -p "$ROOT/.test"
export KIT_ENV_FILE="$ROOT/.test/env"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: test stack '$proj' left running (settings in .test/env)"; return; fi
  COMPOSE_PROJECT_NAME="$proj" dc --profile ui --profile test down -v --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${proj}-mcp:local" "${proj}-mcp-test:local" >/dev/null 2>&1 || true
  rm -rf "$ROOT/.test"
}
if [ "${1:-}" = "--cleanup" ]; then COMPOSE_PROJECT_NAME="$proj"; KEEP=0; [ -f "$KIT_ENV_FILE" ] && cleanup; say "cleaned up $proj"; exit 0; fi
trap cleanup EXIT

make_env "$ROOT/.env.example" "$KIT_ENV_FILE" "$proj"
# port 0 = let the OS pick free ports, so the test never collides with a running client
grep -v -e '^POSTGRES_PORT=' -e '^MCP_PORT=' -e '^NOCODB_PORT=' -e '^KIT_SCOPE=' -e '^ALLOWED_WRITE_ACTORS=' "$KIT_ENV_FILE" > "$KIT_ENV_FILE.tmp"
{ echo "POSTGRES_PORT=${TEST_POSTGRES_PORT:-0}"; echo "MCP_PORT=${TEST_MCP_PORT:-0}"; echo "NOCODB_PORT=${TEST_NOCODB_PORT:-0}"; echo "KIT_SCOPE=write"; echo "ALLOWED_WRITE_ACTORS="; } >> "$KIT_ENV_FILE.tmp"
mv "$KIT_ENV_FILE.tmp" "$KIT_ENV_FILE"; chmod 600 "$KIT_ENV_FILE"
load_env

fails=0
ok()   { say "  PASS  $*"; }
bad()  { say "  FAIL  $*"; fails=$((fails+1)); }

bold "ragnarok data self-test (throwaway project: $proj)"
say "building and starting..."
dc --profile test build mcp mcp-test >/dev/null 2>&1 || { dc --profile test build mcp mcp-test; die "build failed"; }
dc up -d postgres >/dev/null 2>&1 || die "could not start postgres"
wait_pg
# Two access_log receipts written BEFORE db/receipts_v2.sql (receipt format 1, the old trigger), so
# section 0b can prove the upgrade keeps old rows verifying with the hashes they were written with.
admin_psql -q -c "INSERT INTO access_log (tool, ok, scope, actor, via, detail) VALUES ('kit_test_pre_upgrade', true, 'read', 'kit-test', 'test:pre-upgrade', '{\"n\": 1}'), ('kit_test_pre_upgrade', false, 'write', 'kit-test', 'test:pre-upgrade', NULL)" >/dev/null \
  || die "could not write the pre-upgrade receipts"
pre_hashes="$(admin_psql -t -A -c "SELECT string_agg(seq || ':' || hash, ',' ORDER BY seq) FROM access_log")"
pre_max="$(admin_psql -t -A -c "SELECT max(seq) FROM access_log")"
apply_schema

say ""; say "== 0b. Receipt format 2 (db/receipts_v2.sql: model_reported / model_claimed on access_log)"
sq() { admin_psql -t -A -c "$1" 2>&1; }
r="$(sq "SELECT (SELECT string_agg(seq || ':' || hash, ',' ORDER BY seq) FROM access_log) = '$pre_hashes',
  (SELECT count(*) FROM access_log WHERE tool = 'kit_test_pre_upgrade' AND receipt_v IS NULL AND model_reported IS NULL AND model_claimed IS NULL),
  (SELECT bool_and(hash = receipt_chain_hash(prev_hash, to_jsonb(a) - 'hash' - 'prev_hash' - 'receipt_v' - 'model_reported' - 'model_claimed')) FROM access_log a WHERE tool = 'kit_test_pre_upgrade'),
  (SELECT bool_and(intact) FROM kit_verify())")"
[ "$r" = "t|2|t|t" ] && ok "receipts written before the upgrade keep their hashes, stay format 1 (receipt_v NULL), and both chains verify INTACT" || bad "pre-upgrade receipts after the upgrade: $r"
r="$(sq "WITH n AS (INSERT INTO access_log (tool, ok, scope, actor, via, receipt_v, model_reported, model_claimed)
            VALUES ('kit_test_model', true, 'read', 'kit-test', 'test:v2', NULL, 'reported-model:1b', 'claimed-model') RETURNING *)
  SELECT receipt_v, hash = receipt_chain_hash(prev_hash, to_jsonb(n) - 'hash' - 'prev_hash'),
         hash <> receipt_chain_hash(prev_hash, to_jsonb(n) - 'hash' - 'prev_hash' - 'receipt_v' - 'model_reported' - 'model_claimed') FROM n")"
[ "$r" = "2|t|t" ] && ok "a new receipt is stamped format 2 (even if the caller sends NULL) and its hash covers model_reported and model_claimed" || bad "new receipt format: $r"
admin_psql -q < "$ROOT/db/receipts_v2.sql" >/dev/null 2>&1 || bad "re-applying db/receipts_v2.sql failed"
r="$(sq "SELECT (SELECT bool_and(intact) FROM kit_verify()), (SELECT string_agg(seq || ':' || hash, ',' ORDER BY seq) FROM access_log WHERE seq <= $pre_max) = '$pre_hashes'")"
[ "$r" = "t|t" ] && ok "re-applying the upgrade changes nothing; chains still INTACT" || bad "re-apply: $r"
kit_cli seed-sql | admin_psql -q >/dev/null || die "seeding failed"
# made-up business rows (never real data) for the business tools' tests
admin_psql -q < "$ROOT/../connector/test/fixtures/business-fake.sql" >/dev/null || die "loading the fake business rows failed"
dc up -d mcp >/dev/null 2>&1 || die "could not start mcp"
wait_mcp

# ---- connector unit + integration tests (vitest; the business tools against the fake rows).
# Database URLs are built from the throwaway logins and passed by name, never printed.
say ""; say "== 0. Connector unit + integration tests (vitest)"
export BUSINESS_READ_DATABASE_URL="postgresql://$MCP_RO_DB_USER:$MCP_RO_DB_PASSWORD@postgres:5432/$POSTGRES_DB"
export BUSINESS_APP_DATABASE_URL="postgresql://$MCP_DB_USER:$MCP_DB_PASSWORD@postgres:5432/$POSTGRES_DB"
# (vitest's own exit code is carried through the pipe as a last line; colours off, passwords masked)
vt="$( { dc --profile test run --rm --no-deps -T -e NO_COLOR=1 -e BUSINESS_READ_DATABASE_URL -e BUSINESS_APP_DATABASE_URL mcp-test npx vitest run --reporter=verbose 2>&1; echo "VITEST_EXIT=$?"; } \
  | grep -v ' Container ' | sed -e $'s/\x1b\\[[0-9;]*m//g' -e "s/$MCP_DB_PASSWORD/***/g" -e "s/$MCP_RO_DB_PASSWORD/***/g")"
vrc="$(printf '%s\n' "$vt" | sed -n 's/^VITEST_EXIT=//p')"; vrc="${vrc:-1}"
unset BUSINESS_READ_DATABASE_URL BUSINESS_APP_DATABASE_URL
printf '%s\n' "$vt" | grep -E '^ *(✓|×|↓) |Test Files|Tests  |FAIL|Error' | sed -E 's/ [0-9]+ms$//' || printf '%s\n' "$vt" | tail -40
if [ $vrc -eq 0 ] && printf '%s\n' "$vt" | grep -q 'Tests .* passed' && ! printf '%s\n' "$vt" | grep -q -E 'Tests .* (failed|skipped)'; then
  ok "connector vitest suite: $(printf '%s\n' "$vt" | grep -E '^ *Tests ' | sed 's/^ *//')"
else bad "connector vitest suite (exit $vrc)"; fi

# ---- the main test, inside the stack (talks to the MCP server over HTTP and stdio, and to the
# database as admin to approve archives and to tamper with the log on purpose)
export TEST_ADMIN_USER="$POSTGRES_USER" TEST_ADMIN_PASSWORD="$POSTGRES_PASSWORD"
dc run --rm --no-deps -T -e TEST_ADMIN_USER -e TEST_ADMIN_PASSWORD -e TEST_MCP_URL=http://mcp:8787/mcp mcp node dist/test/e2e.js 2> >(grep -v " Container " >&2)
e2e=$?
[ $e2e -eq 0 ] || fails=$((fails+1))

say ""; say "== 12. From outside the stack (the real published port on 127.0.0.1:$MCP_HOST_PORT)"
url="http://127.0.0.1:$MCP_HOST_PORT/mcp"
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$url" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' "$@" -d "$body"; }
c="$(code)";                                   [ "$c" = 401 ] && ok "curl, no token -> 401" || bad "curl, no token -> $c"
c="$(code -H "authorization: Bearer $(rand 32)")"; [ "$c" = 401 ] && ok "curl, wrong token -> 401" || bad "curl, wrong token -> $c"
c="$(code -H "authorization: Bearer $MCP_READ_TOKEN")"; [ "$c" = 200 ] && ok "curl, read-only token -> 200" || bad "curl, read-only token -> $c"
c="$(code -H "authorization: Bearer $MCP_TOKEN")";      [ "$c" = 200 ] && ok "curl, full token -> 200" || bad "curl, full token -> $c"

logs="$(dc logs mcp postgres 2>&1)"
leak=0
for v in "$MCP_TOKEN" "$MCP_READ_TOKEN" "$POSTGRES_PASSWORD" "$MCP_DB_PASSWORD" "$MCP_RO_DB_PASSWORD" "$UI_DB_PASSWORD"; do
  case "$logs" in *"$v"*) leak=1 ;; esac
done
[ $leak = 0 ] && ok "no token or password appears anywhere in the container logs" || bad "a secret appeared in the logs"
case "$logs" in *"refused POST /mcp"*) ok "refused requests are logged (without the token)";; *) bad "refused requests were not logged";; esac

"$ROOT/kit" verify >/dev/null 2>&1; v=$?
[ $v = 1 ] && ok "./kit verify also reports the tampered log (exit 1)" || bad "./kit verify exit $v (expected 1 after tampering)"

say ""; say "== 12b. ./kit anchor against the real (tampered) test database"
a="$("$ROOT/kit" anchor 1 1 2>/dev/null)"; v=$?
if [ $v = 1 ] && printf '%s' "$a" | grep -q '"intact":false' && printf '%s' "$a" | grep -Eq '"check_write_log_hash":"[0-9a-f]{64}"' && printf '%s' "$a" | grep -Eq '"check_access_log_hash":"[0-9a-f]{64}"'; then
  ok "./kit anchor prints one JSON line, reports the tampered log (exit 1) and the hash at seq 1"
else bad "./kit anchor: exit $v: $a"; fi

say ""; say "== 13. ./kit approve needs a person at a terminal"
out="$("$ROOT/kit" approve ARC-NOTTY234 < /dev/null 2>&1)"; v=$?
if [ $v -ne 0 ] && case "$out" in *"not a TTY"*) true;; *) false;; esac; then ok "./kit approve with no terminal (stdin not a TTY) is refused"; else bad "./kit approve without a terminal: exit $v: $out"; fi
out="$(printf 'yes\n' | "$ROOT/kit" approve ARC-NOTTY234 2>&1)"; v=$?
[ $v -ne 0 ] && ok "piping yes into ./kit approve is refused" || bad "piping yes into ./kit approve was accepted: $out"
"$ROOT/scripts/test-local.sh" >/dev/null 2>&1 && ok "scripts/test-local.sh (approve + anchor checks, no Docker) passes" || bad "scripts/test-local.sh failed (run it for details)"

say ""; say "== 14. Brain tables (db/brain.sql: fix-memory in this same Postgres, pgvector, receipts)"
as_psql() { local u="$1"; shift; dc exec -T postgres psql -U "$u" -d "$POSTGRES_DB" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
v="$(as_psql "$POSTGRES_USER" -c "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null)"
[ -n "$v" ] && ok "pgvector extension is installed (version $v)" || bad "pgvector extension missing"
r="$(as_psql "$MCP_DB_USER" 2>&1 <<'SQL'
BEGIN;
SELECT set_config('receipt.actor','kit-test',true), set_config('receipt.note','brain self-test',true) \g /dev/null
INSERT INTO brain.brain_fixes (source, project, error_text, cause, fix) VALUES ('test','kit-test','E: fake failure','fake cause','--- a\n+++ b') RETURNING id \gset
INSERT INTO brain.fix_vectors (fix_id, embedding, embed_model) SELECT :id, array_fill(0.1::real, ARRAY[768])::vector, 'test';
SELECT actor || '|' || note FROM write_log WHERE table_name='brain_fixes' AND record_id = :'id' AND action='INSERT';
COMMIT;
SQL
)"
[ "$r" = "kit-test|brain self-test" ] && ok "AI login adds a fix; the database writes its write_log receipt (actor + note)" || bad "brain insert/receipt: $r"
as_psql "$MCP_DB_USER" -c "UPDATE brain.brain_fixes SET cause='changed'" >/dev/null 2>&1 && bad "AI login could change a stored fix" || ok "AI login cannot change a stored fix"
as_psql "$MCP_DB_USER" -c "DELETE FROM brain.brain_fixes" >/dev/null 2>&1 && bad "AI login could delete a fix" || ok "AI login cannot delete a fix"
as_psql "$MCP_RO_DB_USER" -c "INSERT INTO brain.brain_fix_events (kind) VALUES ('reembed')" >/dev/null 2>&1 && bad "read-only login could add a brain event" || ok "read-only login cannot add brain rows"

say ""; say "== 15. Runner tables (db/runner.sql: the task belt's receipts)"
r="$(as_psql "$MCP_DB_USER" 2>&1 <<'SQL'
BEGIN;
SELECT set_config('receipt.actor','runner:driver',true), set_config('receipt.note','runner self-test',true) \g /dev/null
INSERT INTO runner.runner_events (belt, line_no, line_sha, task, verdict, seat, model, model_reported, actor) VALUES ('kit-test', 1, 'kit-test-sha-1', 't.md', 'check-pass', 'driver', 'qwen2.5-coder:7b', 'qwen2.5-coder:7b', 'runner:driver') RETURNING id \gset
SELECT actor || '|' || note || '|' || coalesce(new_value->>'model_reported', '-') FROM write_log WHERE table_name='runner_events' AND record_id = :'id' AND action='INSERT';
COMMIT;
SQL
)"
[ "$r" = "runner:driver|runner self-test|qwen2.5-coder:7b" ] && ok "AI login adds a runner event (with model_reported); the database writes its write_log receipt" || bad "runner insert/receipt: $r"
as_psql "$MCP_DB_USER" -c "UPDATE runner.runner_events SET verdict='accepted'" >/dev/null 2>&1 && bad "AI login could change a runner event" || ok "AI login cannot change a runner event (e.g. turn a proposal into 'accepted')"
as_psql "$MCP_DB_USER" -c "DELETE FROM runner.runner_events" >/dev/null 2>&1 && bad "AI login could delete a runner event" || ok "AI login cannot delete a runner event"
as_psql "$MCP_DB_USER" -c "INSERT INTO runner.runner_events (belt, line_no, line_sha, task, verdict, actor) VALUES ('kit-test', 1, 'kit-test-sha-1', 't.md', 'x', 'y')" >/dev/null 2>&1 && bad "the same belt line could be copied twice" || ok "the same belt line cannot be copied twice"
as_psql "$MCP_RO_DB_USER" -c "INSERT INTO runner.runner_events (belt, line_no, line_sha, task, verdict, actor) VALUES ('k', 2, 'k2', 't', 'x', 'y')" >/dev/null 2>&1 && bad "read-only login could add a runner event" || ok "read-only login cannot add runner rows"
as_psql "$MCP_DB_USER" -c "INSERT INTO runner.runner_events (belt, line_no, line_sha, task, verdict, actor, proposal) VALUES ('k', 3, 'k3', 't', 'accepted', 'human:x', false)" >/dev/null 2>&1 && bad "AI login could write a person's yes" || ok "AI login cannot write a person's yes (proposal = false)"
as_psql "$MCP_DB_USER" -c "INSERT INTO runner.runner_events (belt, line_no, line_sha, task, verdict, actor) VALUES ('k', 4, 'k4', 't', 'accepted', 'human:x')" >/dev/null 2>&1 && bad "AI login could write a row as a person" || ok "AI login cannot write a row as 'human:...'"

say ""; say "== 16. Run Errors (db/run_errors.sql: model stderr and history decode)"
r="$(as_psql "$POSTGRES_USER" -c "INSERT INTO public.\"Run Errors\" (source, area, message, exit_code) VALUES ('kit-test', 'schema', 'ok', '0') RETURNING source;")"
[ "$r" = "kit-test" ] && ok "admin can add a run error" || bad "admin run error insert: $r"
as_psql "$UI_DB_USER" -t -A -c "SELECT count(*) FROM public.\"Run Errors\" WHERE source='kit-test';" | grep -q '^1$' && ok "NocoDB login can read run errors" || bad "NocoDB login cannot read run errors"
as_psql "$MCP_DB_USER" -c "INSERT INTO public.\"Run Errors\" (source, area, message) VALUES ('x','y','z')" >/dev/null 2>&1 && bad "AI login could add a run error" || ok "AI login cannot add a run error"
as_psql "$MCP_DB_USER" -c "DELETE FROM public.\"Run Errors\"" >/dev/null 2>&1 && bad "AI login could delete a run error" || ok "AI login cannot delete a run error"
as_psql "$POSTGRES_USER" -c "DELETE FROM public.\"Run Errors\" WHERE source='kit-test'" >/dev/null

say ""
if [ $fails -eq 0 ]; then bold "ALL TESTS PASSED"; exit 0; fi
bold "SOME TESTS FAILED ($fails group(s)); see FAIL lines above"; exit 1
