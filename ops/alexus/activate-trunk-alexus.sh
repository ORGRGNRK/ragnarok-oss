#!/usr/bin/env bash
set -euo pipefail

echo "== 1. Setting up ~/Developer/ygg-scratch (Trunk Postgres + NocoDB) =="
if [ ! -d "$HOME/Developer/ygg-scratch" ]; then
  cp -r "$HOME/Developer/RAGNAROK-2026-10-28/scratch-config/ygg-scratch" "$HOME/Developer/ygg-scratch"
fi
cd "$HOME/Developer/ygg-scratch"
if [ ! -f .env ]; then
  sh ./scripts/gen-env.sh
fi
sudo docker compose up -d

echo "== 2. Waiting for ygg-scratch Postgres (port 5547) to be healthy =="
for i in $(seq 1 30); do
  if sudo docker exec ygg-scratch-pg pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
    echo "Postgres is ready!"
    break
  fi
  sleep 2
done

echo "== 3. Running Trunk database migration (transport_log + business schema) =="
cd "$HOME/Developer/ygg-mcp-business"
./scripts/scratch-env.sh npm run migrate

echo "== 4. Creating systemd service (ygg-trunk.service) on port 8787 =="
sudo tee /etc/systemd/system/ygg-trunk.service >/dev/null <<EOF
[Unit]
Description=RAGNAROK Trunk MCP Server (ygg-mcp-business)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$HOME/Developer/ygg-mcp-business
Environment="BUSINESS_HTTP_HOST=0.0.0.0"
Environment="BUSINESS_HTTP_PORT=8787"
Environment="BUSINESS_HTTP_ALLOWED_HOSTS=127.0.0.1,localhost,alexus,rgnrk.co,*.rgnrk.co"
ExecStart=$HOME/Developer/ygg-mcp-business/scripts/scratch-env.sh /usr/bin/node $HOME/Developer/ygg-mcp-business/dist/http.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ygg-trunk.service
sleep 2

echo "== 5. Verifying Trunk Health =="
curl -fsS http://127.0.0.1:8787/health && echo ""
echo "=========================================================="
echo "  RAGNAROK TRUNK LIVE AT: http://alexus:8787/mcp"
echo "=========================================================="
