#!/usr/bin/env bash
#
# Build PhoneGrader.app on macOS (Apple silicon) with full Xcode.
# Mirrors ~/Developer/local-ai-app/build.sh: xcodebuild the SwiftPM package,
# assemble the .app by hand, ad-hoc sign.
#
#   ./build.sh            # tests + Release build -> ./dist/PhoneGrader.app
#   ./build.sh --clean    # wipe ./build and ./dist first
#   SKIP_TESTS=1 ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="PhoneGrader"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Cleaning build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR" "$ROOT/.build"
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if ! xcode-select -p 2>/dev/null | grep -q "Xcode.*\.app"; then
        if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        fi
    fi
fi
echo "==> Using developer dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version

# --- Tests (ported price / deal / listing logic) --------------------------------
if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    echo "==> swift test"
    swift test
fi

# --- Build -------------------------------------------------------------------
echo "==> xcodebuild"
xcodebuild \
    -scheme "$APP_NAME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath ./build \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    build

PRODUCTS="$BUILD_DIR/Build/Products/$CONFIG"
BIN="$PRODUCTS/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "!!  Built executable not found at $BIN"
    ls -la "$PRODUCTS" || true
    exit 1
fi

# --- Assemble the .app -------------------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Data files loaded via Bundle.main (rubric + bundled Atlas cache + real quotes)
for f in rubric.md atlas-ladder.json actual-quotes.json phone.schema.json; do
    cp "$ROOT/Resources/$f" "$APP/Contents/Resources/$f"
    echo "    + Resources/$f"
done

# --- Sign (ad-hoc) -------------------------------------------------------------
echo "==> Ad-hoc codesigning"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo
echo "==> Done: $APP"
echo "    Run:   open \"$APP\""
