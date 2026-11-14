#!/bin/sh
# Docker can start before Tailscale at boot, and the container then can't bind its address.
# Meant for claude@'s crontab at @reboot (not installed yet, see README): wait for the address, then start.
# The address comes from TAILSCALE_IP in the .env next to this file (same one compose.yaml uses).
TAILSCALE_IP="$(sed -n 's/^TAILSCALE_IP=//p' "$(dirname "$0")/.env" 2>/dev/null)"
[ -n "$TAILSCALE_IP" ] || { echo "set TAILSCALE_IP in $(dirname "$0")/.env" >&2; exit 1; }
i=0
while [ $i -lt 120 ]; do
  ip -4 addr show tailscale0 2>/dev/null | grep -qF "inet $TAILSCALE_IP/" && break
  i=$((i + 1)); sleep 5
done
exec docker start bambustudio
