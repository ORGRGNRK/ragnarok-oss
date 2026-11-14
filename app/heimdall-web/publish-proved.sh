#!/bin/bash
# Rebuild the proved-runs page from this Mac's agent runs and put it on Alexus (tailnet only):
#   https://<HEIMDALL_WEB_HOST>/proved
# Runs with a credential shape in them are left out and named. Pass run ids to show only those.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../heimdall/bin/local-config.sh"   # ALEXUS_USER / ALEXUS_TAILSCALE from ~/.ragnarok/local.conf
WEB_HOST=$(lc_get HEIMDALL_WEB_HOST); WEB_HOST=${WEB_HOST:-$ALEXUS_TAILSCALE}
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [ $# -gt 0 ]; then python3 "$here/share-run.py" --all --only "$(IFS=,; echo "$*")" > "$tmp"; else python3 "$here/share-run.py" --all > "$tmp"; fi
ssh "$ALEXUS_USER@$ALEXUS_TAILSCALE" 'install -d -m 700 ~/.ragnarok/heimdall-web && cat > ~/.ragnarok/heimdall-web/proved.html.new && chmod 600 ~/.ragnarok/heimdall-web/proved.html.new && mv ~/.ragnarok/heimdall-web/proved.html.new ~/.ragnarok/heimdall-web/proved.html' < "$tmp"
echo "published: https://$WEB_HOST/proved"
