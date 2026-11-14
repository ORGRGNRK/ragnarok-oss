#!/bin/bash
# Send this Mac's project list (ragnarok-hub) to Alexus so the Hub tab can show it next to Alexus's own.
# Alexus can't look at the Mac by itself; this is a snapshot, and the Hub shows how old it is.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../heimdall/bin/local-config.sh"   # ALEXUS_USER / ALEXUS_TAILSCALE from ~/.ragnarok/local.conf
WEB_HOST=$(lc_get HEIMDALL_WEB_HOST); WEB_HOST=${WEB_HOST:-$ALEXUS_TAILSCALE}
"$here/../heimdall/bin/ragnarok-hub" | ssh "$ALEXUS_USER@$ALEXUS_TAILSCALE" 'install -d -m 700 ~/.ragnarok/heimdall-web && cat > ~/.ragnarok/heimdall-web/hub-mac.json.new && chmod 600 ~/.ragnarok/heimdall-web/hub-mac.json.new && mv ~/.ragnarok/heimdall-web/hub-mac.json.new ~/.ragnarok/heimdall-web/hub-mac.json'
echo "sent: https://$WEB_HOST/hub"
