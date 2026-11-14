#!/usr/bin/env bash
set -euo pipefail

FIDO2_TOKEN="/opt/homebrew/bin/fido2-token"
FIDO2_ASSERT="/opt/homebrew/bin/fido2-assert"

command -v "$FIDO2_TOKEN" >/dev/null 2>&1 || FIDO2_TOKEN="$(command -v fido2-token 2>/dev/null || true)"
command -v "$FIDO2_ASSERT" >/dev/null 2>&1 || FIDO2_ASSERT="$(command -v fido2-assert 2>/dev/null || true)"

if [ -z "$FIDO2_TOKEN" ] || [ -z "$FIDO2_ASSERT" ]; then
  echo "ℹ️ libfido2 tools not found on host." >&2
  exit 3
fi

KEYS_DIRS=("$PWD/keys" "$HOME/.config/fido2/keys" "$HOME/.alexus/keys")
KEYS_BASE=""
for kd in "${KEYS_DIRS[@]}"; do
  if [ -d "$kd" ] && [ -n "$(ls -A "$kd" 2>/dev/null)" ]; then
    KEYS_BASE="$kd"
    break
  fi
done

ALL_DEVS=$("$FIDO2_TOKEN" -L 2>/dev/null || true)
if [ -z "$ALL_DEVS" ]; then
  echo "ℹ️ No FIDO2 hardware security key detected on USB bus." >&2
  exit 3
fi

TARGET_KEY_DIR=""
SELECTED_DEV=""
SELECTED_INFO=""

YUBI_LINE=$(echo "$ALL_DEVS" | grep -iE "yubi|0x1050" | head -1 || true)
if [ -n "$YUBI_LINE" ]; then
  SELECTED_DEV=$(echo "$YUBI_LINE" | cut -d':' -f1,2)
  SELECTED_INFO="$YUBI_LINE"
  if [ -n "$KEYS_BASE" ] && [ -d "$KEYS_BASE/yubikey-primary" ]; then
    TARGET_KEY_DIR="$KEYS_BASE/yubikey-primary"
  fi
fi

if [ -z "$SELECTED_DEV" ]; then
  FIRST_DEV=$(echo "$ALL_DEVS" | head -1)
  SELECTED_DEV=$(echo "$FIRST_DEV" | cut -d':' -f1,2)
  SELECTED_INFO="$FIRST_DEV"
fi

if [ -z "$TARGET_KEY_DIR" ] && [ -n "$KEYS_BASE" ]; then
  for KEY_DIR in "$KEYS_BASE"/*; do
    [ -d "$KEY_DIR" ] || continue
    [ -f "$KEY_DIR/credential_id.txt" ] || continue
    TARGET_KEY_DIR="$KEY_DIR"
    break
  done
fi

if [ -z "$TARGET_KEY_DIR" ] || [ ! -f "$TARGET_KEY_DIR/credential_id.txt" ]; then
  echo "ℹ️ Security key detected ($SELECTED_INFO), but no enrolled key profile found in keys dir." >&2
  exit 3
fi

LABEL=$(basename "$TARGET_KEY_DIR")
RP_ID=$(cat "$TARGET_KEY_DIR/rp_id.txt" 2>/dev/null || echo "mcp-platform")
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

echo "👉 Hardware Security Key detected: $SELECTED_INFO" >&2
echo "👉 Please touch the gold contact sensor on your YubiKey now..." >&2

AUTH_SUCCESS=0
ASSERT_OK=0

if "$FIDO2_ASSERT" -G -t pin=false -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
elif "$FIDO2_ASSERT" -G -u -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
elif "$FIDO2_ASSERT" -G -i "$INPUT_FILE" -o "$ASSERTION_FILE" "$SELECTED_DEV" 2>/dev/null; then
  ASSERT_OK=1
fi

if [ "$ASSERT_OK" -eq 1 ]; then
  head -n 4 "$ASSERTION_FILE" > "$VERIFY_INPUT"
  PUBKEY="$TARGET_KEY_DIR/pubkey.pem"
  [ -f "$PUBKEY" ] || PUBKEY="$TARGET_KEY_DIR/yubikey_pubkey.pem"
  if [ -f "$PUBKEY" ]; then
    if "$FIDO2_ASSERT" -V -i "$VERIFY_INPUT" "$PUBKEY" es256 >/dev/null 2>&1; then
      AUTH_SUCCESS=1
      echo "AUTH_KEY_OK:$LABEL"
    fi
  else
    # Touch presence succeeded
    AUTH_SUCCESS=1
    echo "AUTH_KEY_OK:$LABEL"
  fi
fi

rm -f "$INPUT_FILE" "$ASSERTION_FILE" "$VERIFY_INPUT"

if [ "$AUTH_SUCCESS" -eq 1 ]; then
  exit 0
else
  echo "❌ Physical touch timeout or canceled on security key." >&2
  exit 1
fi
