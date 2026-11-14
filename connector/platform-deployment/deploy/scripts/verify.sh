#!/bin/sh
# Post-install verification. Prints PASS/FAIL per check, never a secret. Exit 0 only if all pass.
#   verify.sh          containers, MCP stdio+HTTP (in container), MCP HTTP from the host, receipts chain, evals (agree mode)
#   verify.sh --quick  same without evals
set -u
cd "$(dirname "$0")/../.."
envval() { sed -n "s/^$1=//p" .env | tail -1; }
fail=0
check() { name=$1; shift; if out=$("$@" 2>&1); then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi; printf '%s\n' "$out" | sed 's/^/     /'; }

check "containers running" sh -c 'for s in pg nocodb mcp; do st=$(docker compose ps --format "{{.Service}} {{.State}} {{.Health}}" $s); echo "$st"; case "$st" in *running*) ;; *) exit 1;; esac; done'
check "MCP stdio + HTTP inside container (9 tools)" docker compose exec -T mcp node scripts/mcp-check.mjs
PORT=$(envval PLATFORM_MCP_HTTP_PORT || true)
[ -z "$PORT" ] && PORT=$(envval YGG_MCP_HTTP_PORT || true)
[ -z "$PORT" ] && PORT=8787
check "MCP HTTP from host 127.0.0.1:$PORT/mcp (9 tools)" sh -c "curl -sS -m 10 -X POST http://127.0.0.1:$PORT/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' \
  | grep -o '\"name\":\"platform_[a-z_]*\"' | sort -u | awk '{print} END{print NR\" tools\"; exit NR==9?0:1}'"
check "receipts chain (mcp.verify)" deploy/scripts/receipts.sh verify
if [ "${1:-}" != --quick ]; then
  check "evals runner (SQL answer key vs tools agree)" docker compose exec -T mcp node scripts/run-evals.mjs --agree
fi
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
