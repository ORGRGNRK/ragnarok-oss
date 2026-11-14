#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
xcodegen generate
xcodebuild -project ALEXUS.xcodeproj -scheme ALEXUSMac -configuration Debug -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ALEXUS_CANONICAL_SOURCE_ROOT="${ALEXUS_SOURCE_ROOT:-$PWD}" build
APP="$PWD/build/Build/Products/Debug/ALEXUSMac.app"
xcrun swiftc Host/EnclaveAuthenticator.swift -o "$APP/Contents/Resources/EnclaveAuthenticator" -framework LocalAuthentication -framework Security -framework CryptoKit
SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
if [[ -z "$SIGN_ID" ]]; then print -u2 'Apple Development signing identity required for installation.'; exit 1; fi
codesign --force --sign "$SIGN_ID" "$APP/Contents/Resources/EnclaveAuthenticator"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
if [[ "${1:-}" == '--install' ]]; then
  DEST="$HOME/Applications/ALEXUS.app"
  if [[ -e "$DEST" ]]; then mv "$DEST" "$HOME/Applications/ALEXUS.previous.$(date +%Y%m%d-%H%M%S).app"; fi
  ditto "$APP" "$DEST"
  print "Installed $DEST"
fi
