#!/bin/bash
# Verify the Mac scratch copy table by table against (a) the Alexus rehearsal targets in
# ygg-rehearsal-pg (live read over ssh, full-row md5) and (b) the recorded rehearsal results
# in expected.txt (rows, max Id, md5 of rows minus Write Log link/Target cols).
# Also: sequences ahead of max Id, Write Log Target_Key resolution, business view, role grants.
# Read-only on both sides (grant tests run inside a rolled-back transaction). Exit 1 on any FAIL.
set -uo pipefail
export PATH=$PATH:/opt/homebrew/bin:$HOME/.orbstack/bin
here=$(cd "$(dirname "$0")" && pwd)
SRC_HOST=${SRC_HOST:-$(sed -n 's/^REHEARSAL_HOST=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}; SKIP_ALEXUS=${SKIP_ALEXUS:-0}
QM() { docker exec -i ygg-scratch-pg psql -U postgres -d "$1" -At -F'|' -c "$2" < /dev/null; }
QA() { echo "$2" | ssh -o BatchMode=yes "$SRC_HOST" "podman exec -i ygg-rehearsal-pg psql -U postgres -d $1 -At -F'|' -f -"; }
EX="array['Business_id','Reminders_id','Knowledge Pipeline_id','Personal - Record of Truth_id','Personal - Resale Inventory_id','Projects_id','Project Steps_id','Social Posts_id','Target_Base','Target_Table','Target_Row_Id','Target_Key']"
fail=0; seen=0
echo "| table | db | rows (exp/mac) | max Id (exp/mac) | seq next > max | md5 vs rehearsal | full-row md5 vs Alexus target | result |"
echo "|---|---|---|---|---|---|---|---|"
while IFS='|' read -r db kb t; do
  case "$db" in ''|\#*) continue;; esac
  IFS='|' read -r _ ec em eh <<<"$(grep "^$t|" "$here/expected.txt")"
  ex="array[]::text[]"; [ "$t" = "Write Log" ] && ex="$EX"
  q="select count(*), coalesce(max(id),0), md5(coalesce(string_agg((to_jsonb(r) - $ex)::text,'|' order by id),'')), md5(coalesce(string_agg(to_jsonb(r)::text,'|' order by id),'')) from \"$t\" r"
  IFS='|' read -r mc mm mh mf <<<"$(QM $db "$q")"
  seq=$(QM $db "select case when is_called then last_value+1 else last_value end from \"${t}_id_seq\"")
  sok=FAIL; [ -n "$seq" ] && [ "$seq" -gt "$mm" ] && sok=ok
  hk=FAIL; [ "${mh:0:8}" = "$eh" ] && hk="match ${eh}"
  if [ "$SKIP_ALEXUS" = 1 ]; then fk=skipped; else
    af=$(QA $db "select md5(coalesce(string_agg(to_jsonb(r)::text,'|' order by id),'')) from \"$t\" r")
    fk=FAIL; [ -n "$af" ] && [ "$af" = "$mf" ] && fk="match ${mf:0:8}"; fi
  r=PASS; { [ "$mc" = "$ec" ] && [ "$mm" = "$em" ] && [ $sok = ok ] && [ "$hk" != FAIL ] && [ "$fk" != FAIL ]; } || { r=FAIL; fail=1; }
  seen=$((seen+1)); echo "| $t | $db | $ec/$mc | $em/$mm | $sok ($seq) | $hk | $fk | $r |"
done < "$here/split.conf"
[ $seen -eq 18 ] && echo "| TABLE COVERAGE | | 18/18 | | | | | PASS |" || { echo "| TABLE COVERAGE | | $seen/18 | | | | | FAIL |"; fail=1; }
# Write Log keys resolve
n=$(QM ygg_receipts "select count(*) from \"Write Log\" where \"Target_Key\" is not null")
orph=0; chk=0
while IFS='|' read -r tb tt ti; do
  [ -z "$tb" ] && continue
  db=$(awk -F'|' -v t="$tt" '$3==t{print $1}' "$here/split.conf"); chk=$((chk+1))
  [ "$(QM $db "select count(*) from \"$tt\" where id=$ti")" = 1 ] || { echo "  orphan: $tb/$tt/$ti"; orph=$((orph+1)); }
done < <(QM ygg_receipts "select distinct \"Target_Base\",\"Target_Table\",\"Target_Row_Id\" from \"Write Log\" where \"Target_Row_Id\" is not null")
{ [ "$n" = 51 ] && [ $orph -eq 0 ] && [ $chk = 36 ]; } && echo "| Write Log Target_Key rows 51, 36 distinct keys resolve | | $n rows / $chk keys | | | | | PASS |" || { echo "| Write Log keys | | $n rows / $chk keys / $orph orphans | | | | | FAIL |"; fail=1; }
m=$(QM ygg_receipts "select count(*) from \"Write Log\" where \"Target_Base\"='machine' and \"Target_Table\"='Machine'")
[ "$m" = 368 ] && echo "| Machine receipts tagged | | 368/$m | | | | | PASS |" || { echo "| Machine receipts | | 368/$m | | | | | FAIL |"; fail=1; }
v=$(QM ygg_business "select count(*) from business_with_totals")
[ "$v" = 92 ] && echo "| view business_with_totals rows | | 92/$v | | | | | PASS |" || { echo "| view rows | | 92/$v | | | | | FAIL |"; fail=1; }
# ownership + grants (rolled back)
own=$(for db in ygg_receipts ygg_ragnarok_core ygg_business ygg_personal ygg_social; do QM $db "select count(*) from pg_tables where schemaname='public' and tableowner<>'ygg_app'"; done | paste -sd+ - | bc)
[ "$own" = 0 ] && echo "| all public tables owned by ygg_app | | | | | | | PASS |" || { echo "| table owners | | $own not ygg_app | | | | | FAIL |"; fail=1; }
ro=$(docker exec -i ygg-scratch-pg psql -U postgres -d ygg_social -At <<'SQL' 2>&1
begin; set local role ygg_read; select 'read_ok:'||count(*) from "Social Posts";
savepoint s; insert into "Social Posts"(id,"Title") values (999998,'x'); rollback to s; rollback;
SQL
)
rw=$(docker exec -i ygg-scratch-pg psql -U postgres -d ygg_social -At <<'SQL' 2>&1
begin; set local role ygg_app; insert into "Social Posts"(id,"Title") values (999999,'grant-test') returning 'write_ok'; rollback;
SQL
)
if echo "$ro" | grep -q read_ok && echo "$ro" | grep -q "permission denied" && echo "$rw" | grep -q write_ok; then echo "| ygg_read select-only, ygg_app read/write (rolled back) | | | | | | | PASS |"; else echo "| grants | | ro=[$ro] rw=[$rw] | | | | | FAIL |"; fail=1; fi
exit $fail
