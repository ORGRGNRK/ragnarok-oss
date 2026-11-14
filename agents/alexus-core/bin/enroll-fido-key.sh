#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-}"

ALL_DEVS=$(/opt/homebrew/bin/fido2-token -L 2>/dev/null || true)

if [ -z "$ALL_DEVS" ]; then
  echo "❌ No FIDO2 hardware security key detected on USB bus." >&2
  exit 1
fi

# Pick first device or match
DEV=$(echo "$ALL_DEVS" | head -1 | cut -d':' -f1,2)
DEV_INFO=$(echo "$ALL_DEVS" | head -1)

if [ -z "$LABEL" ]; then
  if echo "$DEV_INFO" | grep -qi "yubi"; then
    LABEL="yubikey-primary"
  elif echo "$DEV_INFO" | grep -qi "utrust\|identiv"; then
    LABEL="utrust-spare"
  else
    LABEL="fido2-key-$(date +%s)"
  fi
fi

echo "🔑 Detected Hardware Security Key:"
echo "   Device: $DEV"
echo "   Hardware Info: $DEV_INFO"
echo "   Enrollment Label: $LABEL"

KEY_DIR="$HOME/.alexus/keys/$LABEL"
mkdir -p "$KEY_DIR"

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
echo "👉 YOUR SECURITY KEY LED IS BLINKING!"
echo "👉 PLEASE TOUCH THE CONTACT SENSOR ON YOUR KEY NOW..."
echo "👉 ========================================================"
echo ""

CRED_SUCCESS=0
if /opt/homebrew/bin/fido2-cred -M -t pin=false -i "$INPUT_FILE" -o "$OUTPUT_FILE" "$DEV" es256 2>/dev/null; then
  CRED_SUCCESS=1
elif /opt/homebrew/bin/fido2-cred -M -u -i "$INPUT_FILE" -o "$OUTPUT_FILE" "$DEV" es256; then
  CRED_SUCCESS=1
fi

if [ "$CRED_SUCCESS" -eq 1 ]; then
  # fido2-cred -V checks the key's attestation and prints the credential id and the credential's
  # REAL public key (PEM). (Before 2026-10-31 this saved `tail -n +7` of the -M output, which is the
  # factory attestation certificate, so fido-auth.sh's signature check could never pass.)
  VERIFIED_FILE=$(mktemp)
  if ! /opt/homebrew/bin/fido2-cred -V -i "$OUTPUT_FILE" -o "$VERIFIED_FILE" es256; then
    rm -f "$INPUT_FILE" "$OUTPUT_FILE" "$VERIFIED_FILE"
    echo "❌ The key's response did not verify; nothing saved." >&2
    exit 1
  fi
  sed -n '1p' "$VERIFIED_FILE" > "$KEY_DIR/credential_id.txt"
  tail -n +2 "$VERIFIED_FILE" > "$KEY_DIR/pubkey.pem"
  rm -f "$VERIFIED_FILE"
  echo "$DEV_INFO" > "$KEY_DIR/device_info.txt"
  echo "$RP_ID" > "$KEY_DIR/rp_id.txt"
  
  rm -f "$INPUT_FILE" "$OUTPUT_FILE"
  echo ""
  echo "🎉 SUCCESS: Hardware Security Key [$LABEL] Enrolled for ALEXUS Core!"
  echo "   Location: $KEY_DIR"
  echo "   Public Key: $KEY_DIR/pubkey.pem"
  echo "   Credential ID: $(cat "$KEY_DIR/credential_id.txt")"
  exit 0
else
  rm -f "$INPUT_FILE" "$OUTPUT_FILE"
  echo "❌ Hardware enrollment failed or touch was not confirmed." >&2
  exit 1
fi
