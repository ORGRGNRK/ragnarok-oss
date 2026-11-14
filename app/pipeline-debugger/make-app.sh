#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

print "==> Generating Xcode project with xcodegen..."
xcodegen generate

print "==> Building PipelineDebugger with xcodebuild..."
xcodebuild -project PipelineDebugger.xcodeproj -scheme PipelineDebugger -configuration Debug -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

APP="$PWD/build/Build/Products/Debug/Pipeline Debugger.app"
if [[ ! -d "$APP" ]]; then
    # In case the scheme produced PipelineDebugger.app
    APP="$PWD/build/Build/Products/Debug/PipelineDebugger.app"
fi

if [[ ! -d "$APP" ]]; then
    print -u2 "Error: Application bundle not found in build products."
    exit 1
fi

print "==> Signing $APP..."
SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
if [[ -n "$SIGN_ID" ]]; then
    print "Signing with identity: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    print "Signing ad-hoc (-)..."
    codesign --force --deep --sign "-" "$APP"
fi

codesign --verify --strict "$APP"
print "==> Successfully built and signed $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Pipeline Debugger.app"
    mkdir -p "$HOME/Applications"
    if [[ -e "$DEST" ]]; then
        rm -rf "$DEST"
    fi
    ditto "$APP" "$DEST"
    print "==> Installed to $DEST"
fi
