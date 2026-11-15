#!/usr/bin/env bash
# anchor-hourly.sh -- the ONE hourly anchor job on the Mac (launchd co.rgnrk.mac-receipts.anchor).
#
#   1. anchor.sh            -> checks the live AI receipt chain (ygg_receipts.mac.receipts) and anchors it here.
#   2. client kit anchor    -> clients/kit/scripts/mac-anchor.sh for ck-ragnarok-hq (its write_log + access_log),
#                              anchored in ~/RAGNAROK-anchors/ragnarok-hq.jsonl as before.
#   3. Writes the ck-ragnarok-hq result as a receipt INTO mac.receipts (same table, same hash chain), so the
#      client kit's chain heads are hashed into the main chain every hour and its history can't get lost
#      separately. A failed check is logged as a Failed receipt with the problem.
#
# Exit: the worst of the steps (2 = an ALERT somewhere, 3 = something unreachable, 0 = all good).
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
NODE="${RAGNAROK_NODE:-$HOME/.local/node/bin/node}"
DIR="${ANCHOR_DIR:-$HOME/RAGNAROK-anchors}"
worst=0
bump() { [ "$1" = 2 ] && worst=2; [ "$1" = 3 ] && [ "$worst" = 0 ] && worst=3; [ "$1" != 0 ] && [ "$1" != 2 ] && [ "$1" != 3 ] && [ "$worst" = 0 ] && worst="$1"; return 0; }

# 1. live AI receipts
"$HERE/anchor.sh"; bump $?

# 2. client kit: ck-ragnarok-hq on Alexus. Over the tailnet, Tailscale SSH logs in without keys, so the
#    restricted anchor key's forced command never runs; call the kit directly instead.
hq_out="$(ANCHOR_SSH_TARGET="${HQ_SSH_TARGET:-alexus}" \
  ANCHOR_REMOTE_CMD="${HQ_REMOTE_CMD:-cd ~/Developer/ragnarok-hq && ./kit anchor}" \
  ANCHOR_DIR="$DIR" ANCHOR_NAME=ragnarok-hq ANCHOR_NOTIFY="${ANCHOR_NOTIFY:-1}" \
  "$REPO/clients/kit/scripts/mac-anchor.sh" 2>&1)"; hq=$?
printf '%s\n' "$hq_out"; bump $hq

# 3. the result goes into mac.receipts (skip when Alexus was simply unreachable: nothing was read)
if [ "$hq" != 3 ]; then
  last="$(grep -v '^[[:space:]]*$' "$DIR/ragnarok-hq.jsonl" | tail -1)"
  if [ "$hq" = 0 ] && [ -n "$last" ]; then
    cmd="anchor ck-ragnarok-hq: intact; $(echo "$last" | jq -r '"write_log #\(.write_log_seq) head \(.write_log_head); access_log #\(.access_log_seq) head \(.access_log_head)"')"
    "$NODE" "$HERE/receipt.mjs" log --actor "RAGNAROK anchor" --action Read --ref "alexus:ck-ragnarok-hq" --cmd "$cmd" --exit 0 >/dev/null
  else
    prob="$(printf '%s\n' "$hq_out" | grep '^##  - ' | sed 's/^##  - //' | tr '\n' ';' | cut -c1-900)"
    "$NODE" "$HERE/receipt.mjs" log --actor "RAGNAROK anchor" --action Read --ref "alexus:ck-ragnarok-hq" \
      --cmd "anchor ck-ragnarok-hq ALERT: ${prob:-exit $hq}" --exit "$hq" --failed 1 >/dev/null
  fi
fi
exit "$worst"
