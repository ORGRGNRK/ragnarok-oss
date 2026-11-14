#!/usr/bin/env bash
set -euo pipefail
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"

ALEXUS="alexus"
AI_USERS=("argon" "claude" "grok" "codex")

echo "== 1. Generating per-AI SSH keys on your Mac =="
mkdir -p ~/.ssh
chmod 700 ~/.ssh
for U in "${AI_USERS[@]}"; do
  if [ ! -f "$HOME/.ssh/id_${U}" ]; then
    ssh-keygen -t ed25519 -N "" -C "${U}@ragnarok" -f "$HOME/.ssh/id_${U}" >/dev/null
    echo "Generated ~/.ssh/id_${U}"
  fi
done

ARGON_PUB="$(cat ~/.ssh/id_argon.pub)"
CLAUDE_PUB="$(cat ~/.ssh/id_claude.pub)"
GROK_PUB="$(cat ~/.ssh/id_grok.pub)"
CODEX_PUB="$(cat ~/.ssh/id_codex.pub)"

cat > /tmp/apply-ai-keys.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

bash /tmp/setup-ai-users-alexus.sh

install_key() {
  local u="\$1" k="\$2"
  sudo mkdir -p "/home/\$u/.ssh"
  printf '%s\n' "\$k" | sudo tee "/home/\$u/.ssh/authorized_keys" >/dev/null
  sudo chown -R "\$u:\$u" "/home/\$u/.ssh"
  sudo chmod 700 "/home/\$u/.ssh"
  sudo chmod 600 "/home/\$u/.ssh/authorized_keys"
  # Unlock account for SSH pubkey login (set impossible password hash '*' instead of locked '!')
  sudo usermod -p '*' "\$u"
}

install_key argon  "${ARGON_PUB}"
install_key claude "${CLAUDE_PUB}"
install_key grok   "${GROK_PUB}"
install_key codex  "${CODEX_PUB}"

sudo chgrp -R ragnarok-ai /home/${OWNER}/Developer
sudo chmod -R g+rwX /home/${OWNER}/Developer
sudo chmod g+rx /home/${OWNER}
sudo chmod 640 /home/${OWNER}/Developer/ygg-scratch/.env

echo "=========================================================="
echo "  AI SSH ACCOUNTS ACTIVE (argon, claude, grok, codex)"
echo "=========================================================="
EOF

scp ~/Developer/setup-ai-users-alexus.sh /tmp/apply-ai-keys.sh "${OWNER}@${ALEXUS}:/tmp/"
ssh -t "${OWNER}@${ALEXUS}" "bash /tmp/apply-ai-keys.sh"
