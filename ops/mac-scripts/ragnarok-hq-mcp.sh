#!/usr/bin/env bash
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"
# Claude Code -> Ragnarok HQ MCP (stdio over SSH). Same server Gemini's
# launch-alexus-hq.sh reaches; runs as claude (own account, 10-31), actor is
# declared per call as "Claude Code".
exec /usr/bin/ssh -i "$HOME/.ssh/id_claude" -o BatchMode=yes -o IdentitiesOnly=yes \
  -o ConnectTimeout=10 -o ServerAliveInterval=30 claude@alexus \
  "/home/${OWNER}/Developer/ragnarok-hq/kit mcp-stdio"
