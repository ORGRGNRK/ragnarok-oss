#!/bin/sh
# MCP receipts chain in the packaged DB (app_db.mcp.receipts), via the pg container's socket.
#   receipts.sh verify                    -> "ok|checked|reason", exit 0 only if the chain is intact
#   receipts.sh append <actor> <command>  -> appends one receipt through mcp.receipts
#   receipts.sh tail [N]
set -eu
cd "$(dirname "$0")/../.."
q() { docker compose exec -T pg psql -v ON_ERROR_STOP=1 -X -q -U app_owner -d app_db -At "$@"; }
case "${1:-verify}" in
  verify)
    out=$(q -c "select ok, checked, reason from mcp.verify()")
    echo "$out"; case "$out" in t\|*) exit 0;; *) exit 1;; esac ;;
  append)
    [ $# -ge 3 ] || { echo "usage: receipts.sh append <actor> <command>"; exit 2; }
    q -v actor="$2" -v cmd="$3" <<'SQL'
insert into mcp.receipts (tool_name, payload, status)
values (:'actor', jsonb_build_object(
  'command', :'cmd', 'at', now(), 'host', 'docker:' || current_database(),
  'source', 'deploy/scripts/receipts.sh'), 'verified')
returning seq, hash;
SQL
    ;;
  tail)
    q -c "select seq, to_char(created_at, 'YYYY-MM-DD HH24:MI:SSOF'), tool_name, status, prev_hash, hash, payload from mcp.receipts order by seq desc limit ${2:-20}" ;;
  *) echo "usage: receipts.sh verify | append <actor> <command> | tail [N]"; exit 2 ;;
esac
