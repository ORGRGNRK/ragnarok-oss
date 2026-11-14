#!/usr/bin/env bash
# setup-append-only-logs.sh: make the AI logs on Alexus append-only. Run once as root (sudo), from the checkout:
#   sudo bash ~yggdrasil/Developer/ragnarok/ops/alexus/setup-append-only-logs.sh
# Safe to run again. It changes nothing that is already in place and deletes nothing.
#
#   1. Agent ledger: installs /usr/local/libexec/ragnarok-agent-log (root-owned) and one sudo rule so the AI logins
#      can ask the no-login `receipts` account to ADD a record. Ledger: /var/log/ragnarok/agent_events.jsonl,
#      owned by receipts, append-only (chattr +a), hash-chained. Same shape as the SSH receipts already here.
#   2. Room: every AI's own message file (ragnarok-room/data/*.jsonl) is marked append-only, so a posted message
#      or a claimed/finished task can't be edited or removed by the AI that wrote it.
#   3. A small root job (path unit + 5-minute timer) marks new room files, and the web chat log, as they appear.
# Limit, stated plainly: the AI logins are in the `docker` group, which can be used to become root. Append-only
# stops ordinary edits and makes tampering show; it is not a wall against a login that sets out to break it.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
OWNER_HOME="$(getent passwd yggdrasil | cut -d: -f6)"
ROOM_DATA="$OWNER_HOME/Developer/ragnarok-room/data"
LOGDIR=/var/log/ragnarok

echo "== 1. agent ledger"
install -o root -g root -m 755 "$SRC/ragnarok-agent-log" /usr/local/libexec/ragnarok-agent-log
RULE="$(mktemp)"
echo '%ragnarok-ai ALL=(receipts) NOPASSWD: /usr/local/libexec/ragnarok-agent-log' > "$RULE"
visudo -cf "$RULE" >/dev/null
install -o root -g root -m 440 "$RULE" /etc/sudoers.d/ragnarok-agent-log; rm -f "$RULE"
touch "$LOGDIR/agent_events.jsonl" "$LOGDIR/.agent-events.lock" 2>/dev/null || true   # touch fails on an append-only file that exists; fine
chattr -a "$LOGDIR/agent_events.jsonl" 2>/dev/null || true                              # only so owner and mode can be set below
chown receipts:ragnarok-ai "$LOGDIR/agent_events.jsonl"; chmod 640 "$LOGDIR/agent_events.jsonl"
# yggdrasil may read it (for the Timeline and for --verify), exactly as with the SSH receipts. This box has no setfacl,
# so the access list is copied from that file: owner rw, yggdrasil r, group r, others nothing.
python3 -c 'import os,sys; os.setxattr(sys.argv[2], "system.posix_acl_access", os.getxattr(sys.argv[1], "system.posix_acl_access"))' \
  "$LOGDIR/ai_ssh_receipts.jsonl" "$LOGDIR/agent_events.jsonl"
chown receipts:receipts "$LOGDIR/.agent-events.lock"; chmod 600 "$LOGDIR/.agent-events.lock"
chattr +a "$LOGDIR/agent_events.jsonl"

echo "== 2 + 3. the sealing job"
cat > /usr/local/libexec/ragnarok-seal-logs <<SEAL
#!/usr/bin/env bash
# Marks the AI-written logs append-only (chattr +a). Root, run by ragnarok-seal-logs.path and .timer.
# A room file is set to 644 first, so only its owner can add to it: the author shown is the file's owner.
shopt -s nullglob
for f in "$ROOM_DATA"/*.jsonl; do
  [ -f "\$f" ] && [ ! -L "\$f" ] || continue
  lsattr "\$f" 2>/dev/null | cut -d' ' -f1 | grep -q a && continue
  chmod 644 "\$f" && chattr +a "\$f" && echo "sealed \$f"
done
for f in "$OWNER_HOME/.ragnarok/heimdall-chat.jsonl"; do
  [ -f "\$f" ] && [ ! -L "\$f" ] || continue
  lsattr "\$f" 2>/dev/null | cut -d' ' -f1 | grep -q a && continue
  chattr +a "\$f" && echo "sealed \$f"
done
exit 0
SEAL
chmod 755 /usr/local/libexec/ragnarok-seal-logs
cat > /etc/systemd/system/ragnarok-seal-logs.service <<UNIT
[Unit]
Description=Mark the AI-written logs append-only (room files, web chat log)
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/ragnarok-seal-logs
UNIT
cat > /etc/systemd/system/ragnarok-seal-logs.path <<UNIT
[Unit]
Description=Seal a new room file as soon as it appears
[Path]
PathChanged=$ROOM_DATA
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/ragnarok-seal-logs.timer <<UNIT
[Unit]
Description=Seal AI-written logs every 5 minutes (backstop for the path unit)
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now ragnarok-seal-logs.path ragnarok-seal-logs.timer >/dev/null
/usr/local/libexec/ragnarok-seal-logs

echo "== 4. proof (a throwaway room folder, and one real 'install-check' record in the ledger)"
ROOM_BIN="$OWNER_HOME/Developer/ragnarok-room/bin/room"
T="$(sudo -u yggdrasil mktemp -d /tmp/seal-check.XXXXXX)"
say() { sudo -u yggdrasil env RAGNAROK_ROOM="$T" python3 "$ROOM_BIN" say "$1" >/dev/null 2>&1; }
pass() { echo "ok   $1"; }; fail() { echo "FAIL $1"; BAD=1; }; BAD=0
say "first" && F="$(ls "$T"/*.jsonl)" && chmod 644 "$F" && chattr +a "$F"
say "second" && [ "$(wc -l < "$F")" = 2 ] && pass "room: a sealed file still takes new messages" || fail "room: a sealed file refused a new message"
sudo -u yggdrasil sh -c ": > '$F'" 2>/dev/null; [ "$(wc -l < "$F")" = 2 ] && pass "room: its owner can't empty it" || fail "room: its owner emptied it"
sudo -u yggdrasil sed -i 's/first/edited/' "$F" 2>/dev/null; grep -q first "$F" && pass "room: its owner can't edit a line" || fail "room: its owner edited a line"
sudo -u yggdrasil rm -f "$F" 2>/dev/null; [ -f "$F" ] && pass "room: its owner can't delete it" || fail "room: its owner deleted it"
chattr -a "$F"; rm -rf "$T"
L="$LOGDIR/agent_events.jsonl"; N0="$(wc -l < "$L")"
echo '{"_runner":"install-check","note":"setup-append-only-logs.sh ran"}' | sudo -u claude sudo -n -u receipts /usr/local/libexec/ragnarok-agent-log 20261111-000000-5e1f install-check \
  && [ "$(wc -l < "$L")" = "$((N0 + 1))" ] && tail -n 1 "$L" | grep -q '"actor": "claude@' && pass "ledger: the claude login can add a record, and it is signed as claude" || fail "ledger: the claude login could not add a record"
sudo -u claude sh -c ": > '$L'" 2>/dev/null; sudo -u receipts sh -c ": > '$L'" 2>/dev/null
[ "$(wc -l < "$L")" = "$((N0 + 1))" ] && pass "ledger: neither claude nor the receipts account can empty it" || fail "ledger: it was emptied"
sudo -u receipts sed -i 's/install-check/edited/' "$L" 2>/dev/null; tail -n 1 "$L" | grep -q install-check && pass "ledger: the receipts account can't edit a record" || fail "ledger: a record was edited"
sudo -u claude sudo -n -u receipts /usr/local/libexec/ragnarok-agent-log --check 20261111-000000-5e1f install-check /etc/shadow >/dev/null 2>&1 && fail "ledger: --check ran through sudo" || pass "ledger: the writer can't be used through sudo to read other files"
sudo -u yggdrasil /usr/local/libexec/ragnarok-agent-log --verify && pass "ledger: the chain verifies, read as yggdrasil" || fail "ledger: the chain does not verify"

echo "== result"
lsattr "$LOGDIR"/ai_ssh_receipts.jsonl "$LOGDIR"/agent_events.jsonl "$ROOM_DATA"/*.jsonl
ls -l "$LOGDIR"/agent_events.jsonl /usr/local/libexec/ragnarok-agent-log /etc/sudoers.d/ragnarok-agent-log
systemctl is-active ragnarok-seal-logs.path ragnarok-seal-logs.timer
[ "$BAD" = 0 ] && echo "ALL PROVED" || { echo "SOMETHING FAILED, see above"; exit 1; }
