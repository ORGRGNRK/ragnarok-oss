#!/usr/bin/env bash
# Deploy RAGNAROK Sovereign Stack from Mac to bare-metal Ubuntu (alexus @ alexus)
set -euo pipefail

ALEXUS_HOST="${1:-alexus}"
ALEXUS_USER="yggdrasil"
REMOTE="${ALEXUS_USER}@${ALEXUS_HOST}"

echo "== 1. Clearing old SSH host key for ${ALEXUS_HOST} (fresh Ubuntu install) =="
ssh-keygen -R "${ALEXUS_HOST}" 2>/dev/null || true

echo "== 2. Creating ~/Developer on ${REMOTE} =="
ssh -o StrictHostKeyChecking=accept-new "${REMOTE}" "mkdir -p ~/Developer"

echo "== 3. Syncing ragnarok-client-kit & ygg-mcp-business to ${REMOTE}:~/Developer/ =="
rsync -avz --exclude='node_modules' --exclude='.git' --exclude='.DS_Store' \
  "$HOME/Developer/ragnarok-client-kit/" "${REMOTE}:~/Developer/ragnarok-client-kit/"

rsync -avz --exclude='node_modules' --exclude='.git' --exclude='.DS_Store' \
  "$HOME/Developer/ygg-mcp-business/" "${REMOTE}:~/Developer/ygg-mcp-business/"

echo "== 4. Syncing RAGNAROK-2026-10-28 backup bundle =="
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs/RAGNAROK-2026-10-28" ]; then
  rsync -avz --exclude='.DS_Store' \
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/RAGNAROK-2026-10-28/" \
    "${REMOTE}:~/Developer/RAGNAROK-2026-10-28/"
fi

echo "== 5. Bootstrapping Docker, Node.js, LUKS dracut fix, and building Trunk on ${REMOTE} =="
ssh -t "${REMOTE}" 'bash -s' <<'EOF'
set -euo pipefail

echo "--- Fixing LUKS dracut initramfs for clean password prompt on reboot ---"
echo 'add_dracutmodules+=" crypt lvm "' | sudo tee /etc/dracut.conf.d/luks.conf >/dev/null
sudo dracut -f --regenerate-all

echo "--- Installing Docker, Docker Compose, Node.js, and build tools ---"
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 nodejs npm git curl jq netcat-openbsd openssl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

echo "--- Building ygg-mcp-business (Trunk MCP) ---"
cd ~/Developer/ygg-mcp-business
npm install
npm run build

echo "--- Building ragnarok-client-kit MCP ---"
cd ~/Developer/ragnarok-client-kit/mcp
npm install
npm run build

echo ""
echo "=========================================================="
echo "  ALEXUS RAGNAROK NODE READY!"
echo "  Docker: $(sudo docker --version)"
echo "  Compose: $(sudo docker compose version)"
echo "  Node: $(node --version)"
echo "=========================================================="
EOF
