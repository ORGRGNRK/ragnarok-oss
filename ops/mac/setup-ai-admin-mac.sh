#!/bin/bash
# One-time setup: a HIDDEN, SSH-only "ai-admin" account on the owner's MacBook Air, like ai-admin@ on Alexus.
# owner, 2026-11-13: "i cant make an ai admin account since this is my personal and main so i'd have to log in to a
# different user" -> it never logs in at the screen; it is not on the login window; the owner stays on yggdrasil.
#
# What it makes:
#   - user ai-admin, UID 495 (below 500 = hidden from the login window), home /var/ai-admin, random password
#     that is thrown away (the account can't be logged into with a password, at the screen or over SSH).
#   - SSH login ONLY with the owner's two security-key keys (ai_admin_yubikey_sk / ai_admin_utrust_sk), and ONLY from
#     this Mac itself (127.0.0.1 / ::1). The key needs the physical YubiKey or uTrust plugged in.
#   - passwordless sudo for ai-admin (same as Alexus), so an AI session can do admin steps without the owner typing.
#   - every command it runs is logged: /var/log/ragnarok/mac-ai-admin.jsonl (time, command, exit code).
# Remote Login was already on before this script; it doesn't change who else can SSH in.
#
# Run once, in Terminal (needs your password):   sudo bash ~/Developer/ragnarok/ops/mac/setup-ai-admin-mac.sh
# Undo:   sudo bash ~/Developer/ragnarok/ops/mac/setup-ai-admin-mac.sh --remove
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo bash $0"; exit 1; }
U=ai-admin; ID=495; HOME_DIR=/var/ai-admin; OWNER_HOME="$(dscl . -read "/Users/${SUDO_USER:-$(id -un)}" NFSHomeDirectory | awk '{print $2}')"
SHELL_WRAP=/usr/local/bin/ragnarok-ai-admin-shell; LOG=/var/log/ragnarok/mac-ai-admin.jsonl
SUDOERS=/etc/sudoers.d/ai-admin; SSHD=/etc/ssh/sshd_config.d/050-ai-admin.conf

if [ "${1:-}" = "--remove" ]; then
  dscl . -delete /Users/$U 2>/dev/null || true
  rm -rf "$HOME_DIR" "$SUDOERS" "$SSHD" "$SHELL_WRAP"
  sed -i '' "\|^$SHELL_WRAP\$|d" /etc/shells
  echo "ai-admin removed (the log at $LOG is kept)."; exit 0
fi

for k in yubikey utrust; do [ -s "$OWNER_HOME/.ssh/ai_admin_${k}_sk.pub" ] || { echo "missing $OWNER_HOME/.ssh/ai_admin_${k}_sk.pub"; exit 1; }; done
if dscl . -read /Users/$U >/dev/null 2>&1; then echo "ai-admin already exists; refreshing its keys and settings"
elif dscl . -list /Users UniqueID | awk -v id=$ID '$2==id{f=1} END{exit !f}'; then echo "UID $ID is taken; stopping"; exit 1
else
  echo "== creating hidden user $U (UID $ID)"
  dscl . -create /Users/$U
  dscl . -create /Users/$U RealName "AI Admin (SSH only)"
  dscl . -create /Users/$U UniqueID $ID
  dscl . -create /Users/$U PrimaryGroupID 20
  dscl . -create /Users/$U NFSHomeDirectory $HOME_DIR
  dscl . -create /Users/$U IsHidden 1
  dscl . -passwd /Users/$U "$(openssl rand -base64 48)"      # random, never stored or shown
fi

echo "== command log + login shell"
mkdir -p /var/log/ragnarok; touch "$LOG"; chmod 644 "$LOG"; chown root:wheel "$LOG"
mkdir -p /usr/local/bin
cat > "$SHELL_WRAP" <<'EOF'
#!/bin/zsh
# Login shell for ai-admin: runs the SSH command, then appends one JSON line (time, command, exit code) to the log.
LOG=/var/log/ragnarok/mac-ai-admin.jsonl
log() { /usr/bin/python3 -I -c 'import json,sys,time; print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"actor":"ai-admin","from":sys.argv[3],"cmd":sys.argv[1],"rc":int(sys.argv[2])}))' "$1" "$2" "${SSH_CLIENT%% *}" | /usr/bin/sudo -n /usr/bin/tee -a "$LOG" >/dev/null; }
if [ "$1" = "-c" ]; then
  /bin/zsh -c "$2"; rc=$?; log "$2" $rc; exit $rc
fi
log "INTERACTIVE_LOGIN" 0; exec /bin/zsh -l
EOF
chmod 755 "$SHELL_WRAP"; chown root:wheel "$SHELL_WRAP"
grep -qxF "$SHELL_WRAP" /etc/shells || echo "$SHELL_WRAP" >> /etc/shells
dscl . -create /Users/$U UserShell "$SHELL_WRAP"

echo "== keys (security keys only, from this Mac only)"
mkdir -p "$HOME_DIR/.ssh"
: > "$HOME_DIR/.ssh/authorized_keys"
for k in yubikey utrust; do
  echo "from=\"127.0.0.1,::1\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding $(cat "$OWNER_HOME/.ssh/ai_admin_${k}_sk.pub")" >> "$HOME_DIR/.ssh/authorized_keys"
done
chown -R $ID:20 "$HOME_DIR"; chmod 700 "$HOME_DIR" "$HOME_DIR/.ssh"; chmod 600 "$HOME_DIR/.ssh/authorized_keys"

echo "== sudo without a password for ai-admin"
TMP=$(mktemp); echo "$U ALL=(ALL) NOPASSWD: ALL" > "$TMP"
visudo -cf "$TMP" >/dev/null && install -m 440 -o root -g wheel "$TMP" "$SUDOERS"; rm -f "$TMP"

echo "== sshd: ai-admin may only use its key"
cat > "$SSHD" <<'EOF'
# ai-admin: security-key public key only, never a password (setup-ai-admin-mac.sh)
Match User ai-admin
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
EOF
chmod 644 "$SSHD"
/usr/sbin/sshd -t && echo "sshd config ok"

echo
echo "Done. Test (as yggdrasil):  ssh -i ~/.ssh/ai_admin_yubikey_sk ai-admin@127.0.0.1 'sudo -n whoami'   -> root"
