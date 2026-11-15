#!/bin/bash
# Pull the 5 rehearsal DBs from Alexus scratch container ygg-rehearsal-pg (read-only pg_dump)
# and restore them into ygg-scratch-pg, owned by ygg_app. Refuses any other target container.
set -euo pipefail
export PATH=$PATH:/opt/homebrew/bin:$HOME/.orbstack/bin
cd "$(dirname "$0")/.."
SRC_HOST=${SRC_HOST:-$(sed -n 's/^REHEARSAL_HOST=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}; SRC_CT=ygg-rehearsal-pg; CT=ygg-scratch-pg
DBS="ygg_receipts ygg_ragnarok_core ygg_business ygg_personal ygg_social"
for db in $DBS; do
  ssh -o BatchMode=yes "$SRC_HOST" "podman exec $SRC_CT pg_dump -U postgres -Fc $db" > dumps/$db.dump
  chmod 600 dumps/$db.dump
  echo "$db dump $(wc -c < dumps/$db.dump) bytes sha256 $(shasum -a 256 dumps/$db.dump | cut -c1-12)"
  docker exec -i $CT pg_restore -U postgres -d $db --no-owner --no-privileges --role=ygg_app --exit-on-error < dumps/$db.dump
done
docker exec -i $CT sh -c 'for db in '"$DBS"'; do psql -v ON_ERROR_STOP=1 -q -U postgres -d $db -f - <<SQL
grant usage on schema public to ygg_read;
grant select on all tables in schema public to ygg_read;
grant select on all sequences in schema public to ygg_read;
alter default privileges for role ygg_app in schema public grant select on tables to ygg_read;
alter default privileges for role ygg_app in schema public grant select on sequences to ygg_read;
SQL
done'
echo restored+granted
