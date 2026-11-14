#!/usr/bin/env bash
set -euo pipefail

ALEXUS_KEY_DIR="$HOME/.alexus"

if [ ! -f "$ALEXUS_KEY_DIR/credential_id.txt" ] || [ ! -f "$ALEXUS_KEY_DIR/yubikey_pubkey.pem" ]; then
  echo "⚠️ YubiKey credential not enrolled yet. Run './bin/enroll-yubikey.sh' first." >&2
  exit 2
fi

DEV=$(/opt/homebrew/bin/fido2-token -L 2>/dev/null | grep -i "yubi" | head -1 | cut -d':' -f1,2 || true)

if [ -z "$DEV" ]; then
  echo "❌ No YubiKey detected on USB bus." >&2
  exit 1
fi

RP_ID=$(cat "$ALEXUS_KEY_DIR/rp_id.txt")
CRED_ID=$(cat "$ALEXUS_KEY_DIR/credential_id.txt")
CHALLENGE_B64=$(openssl rand -base64 32)

INPUT_FILE=$(mktemp)
ASSERTION_FILE=$(mktemp)
VERIFY_INPUT=$(mktemp)

cat << EOF > "$INPUT_FILE"
$CHALLENGE_B64
$RP_ID
$CRED_ID
EOF

echo "👉 YUBIKEY DETECTED: Please touch the gold contact pad to authorize Alexus..." >&2

if /opt/homebrew/bin/fido2-assert -G -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$DEV"; then
  # Verify assertion signature against public key
  # Input to fido2-assert -V:
  # line 1: client data hash
  # line 2: rp_id
  # line 3: authdata
  # line 4: signature
  head -n 4 "$ASSERTION_FILE" > "$VERIFY_INPUT"
  
  if /opt/homebrew/bin/fido2-assert -V -i "$VERIFY_INPUT" "$ALEXUS_KEY_DIR/yubikey_pubkey.pem" es256 >/dev/null 2>&1; then
    rm -f "$INPUT_FILE" "$ASSERTION_FILE" "$VERIFY_INPUT"
    echo "AUTH_YUBIKEY_OK"
    exit 0
  else
    rm -f "$INPUT_FILE" "$ASSERTION_FILE" "$VERIFY_INPUT"
    echo "❌ Signature verification failed on public key." >&2
    exit 1
  fi
else
  rm -f "$INPUT_FILE" "$ASSERTION_FILE" "$VERIFY_INPUT"
  echo "❌ Physical touch timeout or canceled on YubiKey." >&2
  exit 1
fi
