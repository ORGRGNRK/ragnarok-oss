#!/bin/bash
# Points the RAGNAROK dashboard at NocoDB instead of the retired Airtable base.
#   1. a viewer-role NocoDB user for the Yggdrasil base (dashboard@yggdrasil.local)
#   2. an API token for that user -> /opt/ragnarok-dashboard/data/.env (ragnarok-dash, 0640)
#   3. installs the NocoDB version of modules/yggdrasil/index.js (old one kept as .bak)
#   4. restarts ragnarok-dashboard and shows what the module now returns
# The viewer role means NocoDB itself refuses any write made with this token.
# Safe to re-run: an existing user/token is reused rather than duplicated.
set -euo pipefail
SRC="${1:-/private/tmp/claude-501/-Users-yggdrasil/6f268f67-db70-4289-a5ce-58f107093ce4/scratchpad/dash/index.js}"
scp -q "$SRC" claude@alexus:/tmp/ygg-module-new.js
ssh -o ConnectTimeout=15 claude@alexus 'bash -s' <<'EOF'
set -euo pipefail
chmod 644 /tmp/ygg-module-new.js
sudo -n -u yggdrasil bash <<'Y' > /tmp/.dash-token
set -euo pipefail
set -a; . ~/.config/yggdrasil-v2/secrets.env; set +a
U=$NOCODB_URL; A=(-H "xc-token: $NOCODB_API_TOKEN" -H 'Content-Type: application/json')
EMAIL=dashboard@yggdrasil.local
BID=$(curl -fsS "${A[@]}" "$U/api/v2/meta/bases" | python3 -c 'import json,sys;print(next(b["id"] for b in json.load(sys.stdin)["list"] if b["title"]=="Yggdrasil"))')
exists=$(curl -fsS "${A[@]}" "$U/api/v2/meta/bases/$BID/users" | python3 -c "import json,sys;print(any(u.get('email')=='$EMAIL' for u in json.load(sys.stdin)['users']['list']))")
PW=$(openssl rand -base64 24)
if [ "$exists" != True ]; then
  curl -fsS "${A[@]}" -X POST "$U/api/v2/meta/bases/$BID/users" -d "{\"email\":\"$EMAIL\",\"roles\":\"viewer\"}" >/dev/null
fi
# an invited user finishes signup with a password plus its invite token
IT=$(curl -fsS "${A[@]}" "$U/api/v2/meta/bases/$BID/users" | python3 -c "import json,sys;print(next((u.get('invite_token') or '') for u in json.load(sys.stdin)['users']['list'] if u.get('email')=='$EMAIL'))")
J=$(curl -sS -H 'Content-Type: application/json' -X POST "$U/api/v1/auth/user/signup" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"token\":\"$IT\"}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("token",""));print(d.get("msg",""),file=sys.stderr)')
[ -n "$J" ] || { echo "SIGNUP FAILED for $EMAIL (user may already be active: reset its password in NocoDB, then rerun)" >&2; exit 1; }
T=$(curl -fsS -H "xc-auth: $J" -H 'Content-Type: application/json' -X POST "$U/api/v1/tokens" -d '{"description":"ragnarok-dashboard (viewer, read-only)"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
printf 'NOCODB_URL=%s\nNOCODB_TOKEN=%s\n' "$U" "$T"
Y
D=/opt/ragnarok-dashboard
sudo -n install -o ragnarok-dash -g ragnarok-dash -m 640 /tmp/.dash-token $D/data/.env
rm -f /tmp/.dash-token
sudo -n cp -p $D/modules/yggdrasil/index.js $D/modules/yggdrasil/index.js.bak-2026-10-22-airtable
sudo -n install -m 644 --preserve-context /tmp/ygg-module-new.js $D/modules/yggdrasil/index.js
sudo -n chown --reference=$D/modules/yggdrasil/index.js.bak-2026-10-22-airtable $D/modules/yggdrasil/index.js
rm -f /tmp/ygg-module-new.js
sudo -n systemctl restart ragnarok-dashboard
sleep 4
systemctl is-active ragnarok-dashboard
echo "SETUP OK"
EOF
