#!/bin/bash
# Send this laptop's last 24 hours of activity (ragnarok-timeline) to Alexus so the Timeline tab can show it
# next to Alexus's own. Alexus can't look at the laptop by itself; this is a snapshot, and the tab shows how old it is.
# Titles and bodies are scrubbed of secrets by ragnarok-timeline before they leave this machine.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../heimdall/bin/local-config.sh"   # ALEXUS_USER / ALEXUS_TAILSCALE from ~/.ragnarok/local.conf
WEB_HOST=$(lc_get HEIMDALL_WEB_HOST); WEB_HOST=${WEB_HOST:-$ALEXUS_TAILSCALE}
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
python3 "$here/../heimdall/bin/ragnarok-timeline" > "$tmp"
ssh "$ALEXUS_USER@$ALEXUS_TAILSCALE" 'install -d -m 700 ~/.ragnarok/heimdall-web && cat > ~/.ragnarok/heimdall-web/timeline-mac.json.new && chmod 600 ~/.ragnarok/heimdall-web/timeline-mac.json.new && mv ~/.ragnarok/heimdall-web/timeline-mac.json.new ~/.ragnarok/heimdall-web/timeline-mac.json' < "$tmp"
echo "sent: https://$WEB_HOST/timeline"
