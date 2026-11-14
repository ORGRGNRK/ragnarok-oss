#!/usr/bin/env bash
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"
# Connects Antigravity (Argon) to the ragnarok-trunk MCP on alexus AS argon only.
# No fallback to the owner's account: fails loudly if argon can't log in.
exec /usr/bin/ssh -i "$HOME/.ssh/id_argon" -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new argon@alexus \
  "YGG_SCRATCH_ENV=/home/${OWNER}/Developer/ygg-scratch/.env RAGNAROK_KIT_DIR=/home/${OWNER}/Developer/ragnarok-client-kit RAGNAROK_CLIENT_BASE=/home/${OWNER}/Developer /home/${OWNER}/Developer/ygg-mcp-business/scripts/scratch-env.sh /usr/bin/node /home/${OWNER}/Developer/ygg-mcp-business/dist/index.js"
