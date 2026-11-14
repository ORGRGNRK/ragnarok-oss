#!/usr/bin/env bash
set -euo pipefail

echo "--- Setting passwordless sudo for yggdrasil (optional convenience) & fixing LUKS dracut ---"
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
