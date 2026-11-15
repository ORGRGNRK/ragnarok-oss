#!/usr/bin/env bash
# scripts/test-anchor.sh -- checks scripts/mac-anchor.sh with a FAKE ssh (no network, no server).
# Called by scripts/test-local.sh. Uses a throwaway folder; touches nothing else.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { chflags -R nouappnd "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails+1)); }

cat > "$tmp/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
for last; do :; done
echo "$last" > "$FAKE_DIR/last-cmd"
[ -f "$FAKE_DIR/answer" ] || exit 255
cat "$FAKE_DIR/answer"; exit "$(cat "$FAKE_DIR/rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$tmp/fake-ssh"
H() { printf '%064d' "$1"; }   # a fake 64-character hash
answer() {  # answer PROJECT INTACT WSEQ WHEAD ASEQ AHEAD CWSEQ CWHASH CASEQ CAHASH [rc]
  printf '{"v":1,"project":"%s","at":"2026-10-30T19:00:00Z","intact":%s,"write_log_seq":%s,"write_log_head":"%s","write_log_intact":%s,"write_log_lock":true,"access_log_seq":%s,"access_log_head":"%s","access_log_intact":true,"access_log_lock":true,"check_write_log_seq":%s,"check_write_log_hash":%s,"check_access_log_seq":%s,"check_access_log_hash":%s}\n' \
    "$1" "$2" "$3" "$4" "$2" "$5" "$6" "$7" "$8" "$9" "${10}" > "$tmp/answer"
  echo "${11:-0}" > "$tmp/rc"
}
q() { [ -n "$1" ] && printf '"%s"' "$1" || printf null; }
export FAKE_DIR="$tmp" ANCHOR_SSH="$tmp/fake-ssh" ANCHOR_DIR="$tmp/anchors" ANCHOR_NAME=hq ANCHOR_NOTIFY=0 ANCHOR_APPEND_ONLY=1
run() { "$ROOT/scripts/mac-anchor.sh" >"$tmp/out" 2>"$tmp/err"; echo $?; }
lines() { grep -c . "$ANCHOR_DIR/hq.jsonl" 2>/dev/null || echo 0; }
rejected() { grep -c . "$ANCHOR_DIR/hq.rejected.jsonl" 2>/dev/null || echo 0; }

echo "== scripts/mac-anchor.sh (fake ssh)"
answer ck-hq true 5 "$(H 5)" 10 "$(H 10)" 0 null 0 null
rc=$(run); [ "$rc" = 0 ] && [ "$(lines)" = 1 ] && ok "first run: anchor saved (1 line)" || bad "first run: exit $rc, lines $(lines): $(cat "$tmp/err")"
[ "$(cat "$tmp/last-cmd")" = "anchor 0 0" ] && ok "first run asks the server with no previous seqs" || bad "first run sent: $(cat "$tmp/last-cmd")"
[ "$(git -C "$ANCHOR_DIR" log --oneline | grep -c .)" = 1 ] && ok "anchor committed to the local git repo" || bad "no git commit"

answer ck-hq true 7 "$(H 7)" 12 "$(H 12)" 5 "$(q "$(H 5)")" 10 "$(q "$(H 10)")"
rc=$(run); [ "$rc" = 0 ] && [ "$(lines)" = 2 ] && ok "normal growth: saved (2 lines)" || bad "normal: exit $rc: $(cat "$tmp/err")"
[ "$(cat "$tmp/last-cmd")" = "anchor 5 10" ] && ok "asks for the hashes at the last anchored seqs (anchor 5 10)" || bad "sent: $(cat "$tmp/last-cmd")"

answer ck-hq true 3 "$(H 3)" 12 "$(H 12)" 7 null 12 "$(q "$(H 12)")"
rc=$(run); [ "$rc" = 2 ] && grep -q "ALERT" "$tmp/err" && grep -q "write_log seq went DOWN" "$tmp/err" && ok "seq went down -> ALERT on stderr, exit 2" || bad "seq down: exit $rc: $(cat "$tmp/err")"
[ "$(lines)" = 2 ] && [ "$(rejected)" = 1 ] && ok "bad anchor NOT added to the good file; kept as evidence in .rejected.jsonl" || bad "lines $(lines), rejected $(rejected)"

answer ck-hq true 9 "$(H 9)" 15 "$(H 15)" 7 "$(q "$(H 99)")" 12 "$(q "$(H 12)")"
rc=$(run); [ "$rc" = 2 ] && grep -q "hash at anchored #7 CHANGED" "$tmp/err" && ok "hash at a previously anchored seq changed -> ALERT, exit 2" || bad "hash change: exit $rc: $(cat "$tmp/err")"
[ "$(cat "$tmp/last-cmd")" = "anchor 7 12" ] && ok "after an alert it still compares with the last GOOD anchor (7, 12)" || bad "sent: $(cat "$tmp/last-cmd")"

answer ck-hq false 9 "" 15 "$(H 15)" 7 "$(q "$(H 7)")" 12 "$(q "$(H 12)")" 1
rc=$(run); [ "$rc" = 2 ] && grep -q "NOT clean" "$tmp/err" && ok "server verify says BROKEN -> ALERT, exit 2" || bad "broken: exit $rc: $(cat "$tmp/err")"

answer other-stack true 9 "$(H 9)" 15 "$(H 15)" 7 "$(q "$(H 7)")" 12 "$(q "$(H 12)")"
rc=$(run); [ "$rc" = 2 ] && grep -q "project changed" "$tmp/err" && ok "different project name -> ALERT" || bad "project: exit $rc: $(cat "$tmp/err")"

rm -f "$tmp/answer"
rc=$(run); [ "$rc" = 3 ] && [ "$(lines)" = 2 ] && ok "server unreachable -> exit 3 (not a tamper alert), nothing saved" || bad "unreachable: exit $rc"

answer ck-hq true 9 "$(H 9)" 15 "$(H 15)" 7 "$(q "$(H 7)")" 12 "$(q "$(H 12)")"
rc=$(run); [ "$rc" = 0 ] && [ "$(lines)" = 3 ] && ok "back to normal -> saved again (3 lines)" || bad "recover: exit $rc: $(cat "$tmp/err")"

# agent_log (AI machine receipts): newer kits add a third log; older anchors without it keep working
agent() {  # agent GSEQ GHEAD CGSEQ CGHASH: add agent_log fields to the current answer
  jq -c --argjson g "$1" --arg gh "$2" --argjson cg "$3" --argjson cgh "$4" \
    '. + {agent_log_seq:$g, agent_log_head:$gh, agent_log_intact:true, agent_log_lock:true, check_agent_log_seq:$cg, check_agent_log_hash:$cgh}' \
    "$tmp/answer" > "$tmp/answer.new" && mv "$tmp/answer.new" "$tmp/answer"
}
mk() { answer ck-hq true 9 "$(H 9)" 15 "$(H 15)" 9 "$(q "$(H 9)")" 15 "$(q "$(H 15)")"; }
mk; agent 4 "$(H 4)" 0 null
rc=$(run); [ "$rc" = 0 ] && [ "$(lines)" = 4 ] && [ "$(cat "$tmp/last-cmd")" = "anchor 9 15" ] && ok "kit gains agent_log: saved; asked with two numbers (old anchor had no agent_log)" || bad "agent first: exit $rc sent $(cat "$tmp/last-cmd"): $(cat "$tmp/err")"
mk; agent 6 "$(H 6)" 4 "$(q "$(H 4)")"
rc=$(run); [ "$rc" = 0 ] && [ "$(lines)" = 5 ] && [ "$(cat "$tmp/last-cmd")" = "anchor 9 15 4" ] && ok "next run asks for the agent_log hash too (anchor 9 15 4) and saves" || bad "agent second: exit $rc sent $(cat "$tmp/last-cmd"): $(cat "$tmp/err")"
mk; agent 2 "$(H 2)" 0 null
rc=$(run); [ "$rc" = 2 ] && grep -q "agent_log seq went DOWN" "$tmp/err" && ok "agent_log seq went down -> ALERT" || bad "agent seq down: exit $rc: $(cat "$tmp/err")"
mk; agent 8 "$(H 8)" 6 "$(q "$(H 99)")"
rc=$(run); [ "$rc" = 2 ] && grep -q "agent_log hash at anchored #6 CHANGED" "$tmp/err" && ok "agent_log hash at the anchored seq changed -> ALERT" || bad "agent hash: exit $rc: $(cat "$tmp/err")"
mk
rc=$(run); [ "$rc" = 2 ] && grep -q "agent_log is GONE" "$tmp/err" && ok "agent_log missing from the answer after it was anchored -> ALERT" || bad "agent gone: exit $rc: $(cat "$tmp/err")"
[ "$(lines)" = 5 ] && ok "none of the bad agent_log answers were saved as good" || bad "lines $(lines)"

if [ "$(uname)" = Darwin ]; then
  if ( : > "$ANCHOR_DIR/hq.jsonl" ) 2>/dev/null; then bad "the anchor file could be overwritten"; else ok "the anchor file is append-only (overwrite refused by macOS)"; fi
  [ "$(lines)" = 5 ] && ok "anchor file still has all 5 lines" || bad "anchor file damaged"
fi
[ $fails -eq 0 ] && { echo "  anchor checks passed"; exit 0; }
exit 1
