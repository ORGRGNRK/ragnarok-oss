#!/usr/bin/env bash
# Hardware Presence Platform Unlock
# Unlocks the Docker MCP platform using either:
#   1. YubiKey (FIDO2 physical touch pad)
#   2. Apple Secure Enclave (Touch ID biometrics via macOS LocalAuthentication)
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\033[1;34m[unlock]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[unlock] ✅ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m[unlock] ❌ %s\033[0m\n' "$*" >&2; exit 1; }

METHOD="auto"
for a in "$@"; do
  case "$a" in
    --yubikey|--fido) METHOD="yubikey";;
    --touch-id|--enclave) METHOD="secure_enclave";;
    -h|--help)
      echo "Usage: ./unlock.sh [--yubikey | --touch-id]"
      exit 0
      ;;
  esac
done

AUTH_SUCCESS=0
AUTH_METHOD=""

# 1. Hardware Security Key (YubiKey)
if [ "$METHOD" = "auto" ] || [ "$METHOD" = "yubikey" ]; then
  if [ -x "deploy/auth/fido-auth.sh" ]; then
    say "Checking for connected YubiKey / FIDO2 security key..."
    if deploy/auth/fido-auth.sh; then
      AUTH_SUCCESS=1
      AUTH_METHOD="yubikey"
    elif [ "$METHOD" = "yubikey" ]; then
      err "YubiKey authorization failed or canceled."
    else
      say "No YubiKey active; falling back to Apple Secure Enclave Touch ID..."
    fi
  fi
fi

# 2. Apple Secure Enclave (Touch ID / Native App Gate - macOS only)
if [ "$AUTH_SUCCESS" -eq 0 ] && ([ "$METHOD" = "auto" ] || [ "$METHOD" = "secure_enclave" ]); then
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ -x "deploy/auth/auth-gate" ]; then
      say "Prompting for Apple Secure Enclave (Touch ID) verification..."
      if deploy/auth/auth-gate; then
        AUTH_SUCCESS=1
        AUTH_METHOD="secure_enclave"
      else
        err "Touch ID authorization failed or canceled."
      fi
    elif [ "$METHOD" = "secure_enclave" ]; then
      err "Apple Touch ID gate binary not found. Build with deploy/auth/build-auth.sh first."
    fi
  elif [ "$METHOD" = "secure_enclave" ]; then
    err "Apple Secure Enclave is only available on macOS. On Linux/WSL, use --yubikey."
  fi
fi

[ "$AUTH_SUCCESS" -eq 1 ] || err "No hardware authentication succeeded."

# 3. Transmit unlock to running Docker MCP stack
HTTP_PORT="${PLATFORM_MCP_HTTP_PORT:-${YGG_MCP_HTTP_PORT:-8787}}"
UNLOCK_SECRET=""
if [ -e .env ]; then
  P_PORT=$(sed -n 's/^PLATFORM_MCP_HTTP_PORT=//p' .env | tail -1)
  [ -n "$P_PORT" ] && HTTP_PORT="$P_PORT"
  UNLOCK_SECRET=$(sed -n 's/^PLATFORM_UNLOCK_SECRET=//p' .env | tail -1)
fi

if curl -s -f "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then
  RES=$(curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/unlock" \
    -H "Content-Type: application/json" \
    -d "{\"method\":\"${AUTH_METHOD}\",\"secret\":\"${UNLOCK_SECRET}\"}")
  ok "Platform unlocked via ${AUTH_METHOD}!"
  say "Status: $(echo "$RES" | grep -o '"status":{[^}]*}' || echo "healthy")"
else
  ok "Hardware presence confirmed via ${AUTH_METHOD}. (Docker container not running on port ${HTTP_PORT} yet; start with ./install.sh)"
fi
