#!/usr/bin/env bash
# ./kit test -- proves the kit works, on a THROWAWAY copy of the stack:
#   separate docker project (<name>-test), its own fresh secrets, its own empty database,
#   random free ports. The client's real data, .env and containers are never touched.
# It uses this folder's client/schema.json + seed.json, so it also proves the client's schema works.
# Steps: start -> apply schema -> seed -> run mcp/test/e2e.ts inside the stack -> extra checks from
# outside (real HTTP port, token never in logs, ./kit verify catches the tamper) -> delete it all.
#   KEEP=1 ./kit test   leaves the test stack running for a look (remove later: KEEP=0 ./kit test --cleanup)
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
cd "$ROOT"

base="client-kit"
if [ -f "$ROOT/.env" ]; then base="$(grep '^COMPOSE_PROJECT_NAME=' "$ROOT/.env" | cut -d= -f2)"; fi
proj="${base:-client-kit}-test"
mkdir -p "$ROOT/.test"
export KIT_ENV_FILE="$ROOT/.test/env"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: test stack '$proj' left running (settings in .test/env)"; return; fi
  COMPOSE_PROJECT_NAME="$proj" dc --profile ui down -v --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${proj}-mcp:local" >/dev/null 2>&1 || true
  rm -rf "$ROOT/.test"
}
if [ "${1:-}" = "--cleanup" ]; then COMPOSE_PROJECT_NAME="$proj"; KEEP=0; [ -f "$KIT_ENV_FILE" ] && cleanup; say "cleaned up $proj"; exit 0; fi
trap cleanup EXIT

make_env "$ROOT/.env.example" "$KIT_ENV_FILE" "$proj"
# port 0 = let the OS pick free ports, so the test never collides with a running client
grep -v -e '^POSTGRES_PORT=' -e '^MCP_PORT=' -e '^NOCODB_PORT=' -e '^KIT_SCOPE=' -e '^ALLOWED_WRITE_ACTORS=' "$KIT_ENV_FILE" > "$KIT_ENV_FILE.tmp"
{ echo "POSTGRES_PORT=0"; echo "MCP_PORT=0"; echo "NOCODB_PORT=0"; echo "KIT_SCOPE=write"; echo "ALLOWED_WRITE_ACTORS="; } >> "$KIT_ENV_FILE.tmp"
mv "$KIT_ENV_FILE.tmp" "$KIT_ENV_FILE"; chmod 600 "$KIT_ENV_FILE"
load_env

fails=0
ok()   { say "  PASS  $*"; }
bad()  { say "  FAIL  $*"; fails=$((fails+1)); }

bold "client-kit self-test (throwaway project: $proj)"
say "building and starting..."
dc build mcp >/dev/null 2>&1 || { dc build mcp; die "build failed"; }
dc up -d postgres >/dev/null 2>&1 || die "could not start postgres"
wait_pg
apply_schema
kit_cli seed-sql | admin_psql -q >/dev/null || die "seeding failed"
dc up -d mcp >/dev/null 2>&1 || die "could not start mcp"
wait_mcp

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

say ""; say "== 14. ./kit money: report from the FAKE demo business, load it, load it again"
python3 -I "$ROOT/money/test_money.py" >/dev/null 2>&1 && ok "money/test_money.py: all 10 planted leaks found" || bad "money/test_money.py failed (run it for details)"
mkdir -p "$ROOT/.test/client" "$ROOT/.test/demo"
cp "$KIT_CLIENT_DIR"/*.json "$ROOT/.test/client/"
export KIT_CLIENT_DIR="$ROOT/.test/client" KIT_HOME="$ROOT/.test"
python3 -I "$ROOT/money/demo/make-demo.py" "$ROOT/.test/demo" >/dev/null
"$ROOT/kit" money add-tables >/dev/null 2>&1 && ok "./kit money add-tables made the two tables" || bad "./kit money add-tables failed"
"$ROOT/kit" money "$ROOT/.test/demo"/*.csv >/dev/null 2>&1 && [ -f "$(ls -1d "$ROOT/.test/money-reports"/*/ | tail -1)report.html" ] \
  && ok "./kit money wrote a report" || bad "./kit money did not write a report"
perm="$(stat -f %Lp "$(ls -1d "$ROOT/.test/money-reports"/*/ | tail -1)" 2>/dev/null || stat -c %a "$(ls -1d "$ROOT/.test/money-reports"/*/ | tail -1)")"
[ "$perm" = 700 ] && ok "report folder is private (700)" || bad "report folder mode $perm, expected 700"
"$ROOT/kit" money load >/dev/null 2>&1 || bad "./kit money load failed"
n1="$(admin_psql -t -A -c "SELECT count(*) FROM money_transactions")"; f1="$(admin_psql -t -A -c "SELECT count(*) FROM money_findings")"
"$ROOT/kit" money load >/dev/null 2>&1 || bad "./kit money load (second time) failed"
n2="$(admin_psql -t -A -c "SELECT count(*) FROM money_transactions")"
[ "${n1:-0}" -gt 2000 ] && [ "${f1:-0}" -ge 10 ] && ok "loaded $n1 transactions and $f1 findings" || bad "loaded only ${n1:-0} transactions / ${f1:-0} findings"
[ "$n1" = "$n2" ] && ok "loading the same report again added nothing" || bad "second load changed the count: $n1 -> $n2"
r="$(admin_psql -t -A -c "SELECT count(*) FROM write_log WHERE table_name = 'money_transactions' AND actor LIKE 'money import%'")"
[ "$r" = "$n1" ] && ok "every loaded row has a receipt ($r)" || bad "receipts $r for $n1 rows"
leak="$(admin_psql -t -A -c "SELECT count(*) FROM money_findings WHERE title ILIKE '%cash advance%'")"
[ "${leak:-0}" -ge 1 ] && ok "the cash advance finding is in the database (NocoDB can show it)" || bad "cash advance finding missing from the database"

say ""
if [ $fails -eq 0 ]; then bold "ALL TESTS PASSED"; exit 0; fi
bold "SOME TESTS FAILED ($fails group(s)); see FAIL lines above"; exit 1
