#!/usr/bin/env bash
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"
# Connects Antigravity (Argon) to the ragnarok-hq MCP on alexus AS argon only.
# No fallback to the owner's account: if argon can't log in, this fails loudly
# so receipts never silently record an AI as the owner account.
exec /usr/bin/ssh -i "$HOME/.ssh/id_argon" -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new argon@alexus \
  "/home/${OWNER}/Developer/ragnarok-hq/kit mcp-stdio"
