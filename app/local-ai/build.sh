#!/usr/bin/env bash
#
# Build LocalAI.app on macOS (Apple silicon) with full Xcode.
#
#   ./build.sh            # Release build -> ./dist/LocalAI.app
#   ./build.sh --clean    # wipe ./build and ./dist first
#
# xcodebuild (not `swift build`) is required: only Xcode's build system compiles
# mlx-swift's Metal shaders into mlx-swift_Cmlx.bundle/.../default.metallib.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="LocalAI"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Cleaning build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi

# --- Toolchain ---------------------------------------------------------------
# Use full Xcode even if xcode-select points at the Command Line Tools
# (the CLT have no Metal compiler and no xcodebuild).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if ! xcode-select -p 2>/dev/null | grep -q "Xcode.*\.app"; then
        if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        fi
    fi
fi
echo "==> Using developer dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version

# Since Xcode 26 the Metal toolchain is a separate download. Warn (don't fail)
# if it looks missing; xcodebuild will error clearly if it really is.
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "!!  WARNING: the Metal compiler doesn't seem to be installed. If the build fails"
    echo "    compiling .metal files, run:  xcodebuild -downloadComponent MetalToolchain"
fi

# --- Build -------------------------------------------------------------------
# ARCHS=arm64 / ONLY_ACTIVE_ARCH=YES: Release otherwise builds a universal binary,
# doubling the (long) C++/Metal build of MLX for an x86_64 slice we don't need.
echo "==> xcodebuild (first build resolves packages and compiles MLX; expect several minutes)"
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
    echo "    Contents of $PRODUCTS:"
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

# SwiftPM resource bundles (mlx-swift_Cmlx.bundle with default.metallib,
# swift-transformers_Hub.bundle, ...). Xcode-generated `Bundle.module` accessors
# and MLX's metallib lookup both search Bundle.main.resourceURL = Contents/Resources.
shopt -s nullglob
bundles=("$PRODUCTS"/*.bundle)
shopt -u nullglob
if (( ${#bundles[@]} == 0 )); then
    echo "!!  No SwiftPM resource bundles found in $PRODUCTS"
    exit 1
fi
for b in "${bundles[@]}"; do
    echo "    + Resources/$(basename "$b")"
    cp -R "$b" "$APP/Contents/Resources/"
done

CMLX_BUNDLE="$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
METALLIB="$(find "$CMLX_BUNDLE" -name 'default.metallib' -print -quit 2>/dev/null || true)"
if [[ -z "$METALLIB" ]]; then
    echo "!!  default.metallib not found inside mlx-swift_Cmlx.bundle — Metal shaders were not compiled."
    echo "    Make sure you're building with full Xcode (xcodebuild), not 'swift build'."
    exit 1
fi
echo "    metallib: ${METALLIB#$APP/}"
# Extra fallback: also place it at Contents/Resources/mlx.metallib (the app sets
# MLX's GPU.metallib override to the first of these that exists).
cp "$METALLIB" "$APP/Contents/Resources/mlx.metallib"

# Dynamic package frameworks, if Xcode produced any (normally everything is static).
if [[ -d "$PRODUCTS/PackageFrameworks" ]]; then
    shopt -s nullglob
    fws=("$PRODUCTS"/PackageFrameworks/*.framework)
    shopt -u nullglob
    if (( ${#fws[@]} > 0 )); then
        mkdir -p "$APP/Contents/Frameworks"
        for fw in "${fws[@]}"; do
            echo "    + Frameworks/$(basename "$fw")"
            cp -R "$fw" "$APP/Contents/Frameworks/"
        done
        install_name_tool -add_rpath "@executable_path/../Frameworks" \
            "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    fi
fi

# --- Sign (ad-hoc) -------------------------------------------------------------
# No App Sandbox entitlement: the app must read ~/.lmstudio/... with the real home path.
echo "==> Ad-hoc codesigning"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" || {
    echo "!!  codesign verification reported problems (see above)"
}

echo
echo "==> Done: $APP"
echo "    Run:   open \"$APP\""
echo "    Logs:  \"$APP/Contents/MacOS/$APP_NAME\"   (run from Terminal to see stdout/stderr)"
