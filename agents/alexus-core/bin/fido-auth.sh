#!/usr/bin/env bash
set -euo pipefail

KEYS_BASE="$HOME/.alexus/keys"

if [ ! -d "$KEYS_BASE" ] || [ -z "$(ls -A "$KEYS_BASE" 2>/dev/null)" ]; then
  echo "ℹ️ No hardware keys enrolled in $KEYS_BASE." >&2
  exit 3
fi

ALL_DEVS=$(/opt/homebrew/bin/fido2-token -L 2>/dev/null || true)

if [ -z "$ALL_DEVS" ]; then
  echo "ℹ️ No FIDO2 hardware security key plugged in." >&2
  exit 3
fi

# Detect which key is plugged in (Prioritize Primary YubiKey, Fallback to uTrust Spare)
TARGET_KEY_DIR=""
SELECTED_DEV=""
SELECTED_INFO=""

# Priority 1: Check if Primary YubiKey is plugged in
YUBI_LINE=$(echo "$ALL_DEVS" | grep -iE "yubi|0x1050" | head -1 || true)
if [ -n "$YUBI_LINE" ] && [ -d "$KEYS_BASE/yubikey-primary" ]; then
  TARGET_KEY_DIR="$KEYS_BASE/yubikey-primary"
  SELECTED_DEV=$(echo "$YUBI_LINE" | cut -d':' -f1,2)
  SELECTED_INFO="$YUBI_LINE"
fi

# Priority 2: Fallback to uTrust Spare key if YubiKey is not present
if [ -z "$TARGET_KEY_DIR" ]; then
  UTRUST_LINE=$(echo "$ALL_DEVS" | grep -iE "utrust|identiv|0x04e6" | head -1 || true)
  if [ -n "$UTRUST_LINE" ] && [ -d "$KEYS_BASE/utrust-spare" ]; then
    TARGET_KEY_DIR="$KEYS_BASE/utrust-spare"
    SELECTED_DEV=$(echo "$UTRUST_LINE" | cut -d':' -f1,2)
    SELECTED_INFO="$UTRUST_LINE"
  fi
fi

# Priority 3: Any other enrolled key matching connected devices
if [ -z "$TARGET_KEY_DIR" ]; then
  for KEY_DIR in "$KEYS_BASE"/*; do
    [ -d "$KEY_DIR" ] || continue
    [ -f "$KEY_DIR/credential_id.txt" ] || continue
    FIRST_DEV=$(echo "$ALL_DEVS" | head -1)
    TARGET_KEY_DIR="$KEY_DIR"
    SELECTED_DEV=$(echo "$FIRST_DEV" | cut -d':' -f1,2)
    SELECTED_INFO="$FIRST_DEV"
    break
  done
fi

if [ -z "$TARGET_KEY_DIR" ]; then
  echo "ℹ️ Connected USB device does not match any enrolled keys." >&2
  exit 3
fi

LABEL=$(basename "$TARGET_KEY_DIR")
RP_ID=$(cat "$TARGET_KEY_DIR/rp_id.txt" 2>/dev/null || echo "alexus-core")
CRED_ID=$(cat "$TARGET_KEY_DIR/credential_id.txt")

CHALLENGE_B64=$(openssl rand -base64 32)
INPUT_FILE=$(mktemp)
ASSERTION_FILE=$(mktemp)
VERIFY_INPUT=$(mktemp)

cat << EOF > "$INPUT_FILE"
$CHALLENGE_B64
$RP_ID
$CRED_ID
EOF

if [ "$LABEL" = "yubikey-primary" ]; then
  echo "👉 Primary Key [$LABEL] detected ($SELECTED_INFO)" >&2
  echo "👉 Please touch the GOLD CONTACT on your YubiKey..." >&2
else
  echo "👉 Spare Key [$LABEL] detected as fallback ($SELECTED_INFO)" >&2
  echo "👉 Please touch the CONTACT SENSOR on your spare key..." >&2
fi

AUTH_SUCCESS=0
ASSERT_OK=0

if /opt/homebrew/bin/fido2-assert -G -t pin=false -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
elif /opt/homebrew/bin/fido2-assert -G -u -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
elif /opt/homebrew/bin/fido2-assert -G -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
fi

if [ "$ASSERT_OK" -eq 1 ]; then
  head -n 4 "$ASSERTION_FILE" > "$VERIFY_INPUT"
  if /opt/homebrew/bin/fido2-assert -V -i "$VERIFY_INPUT" "$TARGET_KEY_DIR/pubkey.pem" es256 >/dev/null 2>&1; then
    AUTH_SUCCESS=1
    echo "AUTH_KEY_OK:$LABEL"
  fi
fi

rm -f "$INPUT_FILE" "$ASSERTION_FILE" "$VERIFY_INPUT"

if [ "$AUTH_SUCCESS" -eq 1 ]; then
  exit 0
else
  echo "❌ Physical touch timeout, canceled, or key not recognized." >&2
  exit 1
fi
