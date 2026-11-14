#!/usr/bin/env bash
set -euo pipefail

DEV=$(/opt/homebrew/bin/fido2-token -L 2>/dev/null | grep -i "yubi" | head -1 | cut -d':' -f1,2 || true)

if [ -z "$DEV" ]; then
  echo "❌ No YubiKey detected. Please make sure your YubiKey is plugged in." >&2
  exit 1
fi

echo "🔑 Detected YubiKey on: $DEV"

ALEXUS_KEY_DIR="$HOME/.alexus"
mkdir -p "$ALEXUS_KEY_DIR"

RP_ID="alexus-core"
USER_NAME="$(id -F 2>/dev/null || id -un)"
USER_ID_B64=$(echo -n "$(id -un)-rgnrk" | base64)
CHALLENGE_B64=$(openssl rand -base64 32)

INPUT_FILE=$(mktemp)
OUTPUT_FILE=$(mktemp)

cat << EOF > "$INPUT_FILE"
$CHALLENGE_B64
$RP_ID
$USER_NAME
$USER_ID_B64
EOF

echo ""
echo "👉 ========================================================"
echo "👉 YOUR YUBIKEY LED IS BLINKING!"
echo "👉 PLEASE TOUCH THE GOLD CONTACT PAD ON YOUR YUBIKEY NOW..."
echo "👉 ========================================================"
echo ""

if /opt/homebrew/bin/fido2-cred -M -i "$INPUT_FILE" -o "$OUTPUT_FILE" "$DEV" es256; then
  # Extract public key (line 7 onwards) and save
  tail -n +7 "$OUTPUT_FILE" > "$ALEXUS_KEY_DIR/yubikey_pubkey.pem"
  # Extract credential ID (line 5)
  sed -n '5p' "$OUTPUT_FILE" > "$ALEXUS_KEY_DIR/credential_id.txt"
  echo "$DEV" > "$ALEXUS_KEY_DIR/yubikey_device.txt"
  echo "$RP_ID" > "$ALEXUS_KEY_DIR/rp_id.txt"
  
  rm -f "$INPUT_FILE" "$OUTPUT_FILE"
  echo ""
  echo "🎉 SUCCESS: YubiKey hardware credential enrolled for ALEXUS Core!"
  echo "   Public Key: $ALEXUS_KEY_DIR/yubikey_pubkey.pem"
  echo "   Credential ID: $(cat "$ALEXUS_KEY_DIR/credential_id.txt")"
  exit 0
else
  rm -f "$INPUT_FILE" "$OUTPUT_FILE"
  echo "❌ YubiKey enrollment failed or touch was not detected." >&2
  exit 1
fi
