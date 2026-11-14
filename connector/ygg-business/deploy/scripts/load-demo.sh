#!/bin/sh
# Optional: load generic demo rows (deploy/demo/demo-data.sql) into an empty app_db.
#   load-demo.sh           refuses if public.items already has rows
#   load-demo.sh --remove  deletes rows
set -eu
cd "$(dirname "$0")/../.."
q() { docker compose exec -T pg psql -v ON_ERROR_STOP=1 -X -q -U app_owner -d app_db -At "$@"; }
if [ "${1:-}" = --remove ]; then
  q -c "delete from public.items; delete from public.leads; delete from public.channels; delete from mcp.search_vectors; delete from mcp.index_state;"
  echo "load-demo: demo rows removed"; exit 0
fi
n=$(q -c 'select count(*) from public.items')
[ "$n" = 0 ] || { echo "load-demo: public.items already has $n rows; refusing (demo data is for empty installs only)"; exit 1; }
q -f - < deploy/demo/demo-data.sql
echo "load-demo: loaded $(q -c 'select count(*) from public.items') demo items, $(q -c 'select count(*) from public.leads') leads, $(q -c 'select count(*) from public.channels') channels"
