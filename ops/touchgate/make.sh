#!/bin/sh
# Build the Touch ID helper into ~/.touchgate/bin/touchgate-auth.
# The binary is not part of the git tree. Linux support is planned.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ "$(uname -s)" != "Darwin" ]; then
  echo "touchgate-auth is macOS-only (Touch ID). Linux support is planned. The hook fails closed until then." >&2
  exit 1
fi
DEST=${TOUCHGATE_BIN:-"$HOME/.touchgate/bin"}
mkdir -p "$DEST"
if [ -d "$HOME/.touchgate" ]; then
  chmod 700 "$HOME/.touchgate" || true
fi
chmod 700 "$DEST" || true
swiftc -O -o "$DEST/touchgate-auth" "$ROOT/swift/touchgate-auth.swift"
chmod 755 "$DEST/touchgate-auth"
echo "Built $DEST/touchgate-auth"
