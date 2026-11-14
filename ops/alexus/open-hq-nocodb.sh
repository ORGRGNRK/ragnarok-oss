#!/usr/bin/env bash
# Opens an SSH port-forward to alexus for ragnarok-hq NocoDB (8092) and
# hilife-motorsports NocoDB (8100), as argon only, and opens HQ in the browser.
# The HQ base is already connected to its Postgres, so no password is printed.
set -euo pipefail
KEY="$HOME/.ssh/id_argon"
USER_TARGET="argon@alexus"

pkill -f "8092:127.0.0.1:8092" 2>/dev/null || true
echo "== Starting background SSH tunnel to alexus (8092 & 8100) as ${USER_TARGET} =="
ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -f -N \
  -L 8092:127.0.0.1:8092 \
  -L 8100:127.0.0.1:8100 \
  "$USER_TARGET"
echo "RAGNAROK HQ NocoDB: http://127.0.0.1:8092   (HiLife demo: http://127.0.0.1:8100)"
open "http://127.0.0.1:8092"
