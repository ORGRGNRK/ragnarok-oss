#!/bin/sh
# Optional, HUMAN-APPROVED: load real Business data from a pg_dump custom-format file of ygg_business
# (e.g. ~/Developer/ygg-scratch/dumps/ygg_business.dump) into this install. Data only: the schema
# already exists from initdb. Refuses if public."Business" has rows. The dump is streamed from
# the host; nothing is copied into the image or the repo.
#   restore-dump.sh /path/to/ygg_business.dump
set -eu
DUMP=${1:?usage: restore-dump.sh /path/to/ygg_business.dump}
[ -r "$DUMP" ] || { echo "restore-dump: cannot read $DUMP"; exit 2; }
cd "$(dirname "$0")/../.."
q() { docker compose exec -T pg psql -v ON_ERROR_STOP=1 -X -q -U postgres -d ygg_business -At "$@"; }
n=$(q -c 'select count(*) from public."Business"')
[ "$n" = 0 ] || { echo "restore-dump: public.\"Business\" already has $n rows; refusing"; exit 1; }
# --disable-triggers needs a superuser (postgres, local socket inside the container).
docker compose exec -T pg pg_restore -U postgres -d ygg_business --data-only --disable-triggers \
  --no-owner --no-privileges --exit-on-error -n public < "$DUMP"
# Only schema public is restored. The dump's mcp.* rows (old tool-call receipts, search cache) are
# skipped: this install keeps its own receipts, and the search cache rebuilds itself.
q -c "truncate mcp.search_vectors, mcp.index_state" >/dev/null
echo "restore-dump: restored; Business rows: $(q -c 'select count(*) from public."Business"')"
