#!/bin/bash
# make-app.sh: build Ragnarok (build/Heimdall.app) from this package into build/.
# Includes the Control Center tiles (Controls/, a WidgetKit extension). Signed with the owner's Apple Development identity,
# which the tiles need; if that identity isn't on this Mac it falls back to ad-hoc signing WITHOUT the tiles.
# Giving it to other people needs a Developer ID signature and notarization.
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=build/Heimdall.app
# Signing identity: RAGNAROK_SIGN_ID, else the first "Apple Development" identity in this Mac's keychain.
SIGN="${RAGNAROK_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
SIGN="${SIGN:-no-apple-development-identity}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
git rev-parse --short HEAD > "$APP/Contents/Resources/commit" 2>/dev/null || echo none > "$APP/Contents/Resources/commit"
cp .build/release/Heimdall "$APP/Contents/MacOS/Heimdall"
# Shared ALEXUS companion panels use the same private host and original source root.
# Keep the repair target ALEXUS; this host never installs over Ragnarok.
ALEXUS_ROOT="$(cd ../alexus && pwd)"
for host in alexus_host chat_host remote_host deployment_host; do
  cp "$ALEXUS_ROOT/Host/$host.py" "$APP/Contents/Resources/"
done
cp "$ALEXUS_ROOT/Resources/Foundation.json" "$ALEXUS_ROOT/Resources/Ragnarok.png" "$APP/Contents/Resources/"
xcrun swiftc "$ALEXUS_ROOT/Host/EnclaveAuthenticator.swift" -o "$APP/Contents/Resources/EnclaveAuthenticator" \
  -framework LocalAuthentication -framework Security -framework CryptoKit
# Bundle Heimdall's own runtime scripts and alexus-core helpers inside Contents/Resources so Ragnarok.app is self-contained.
mkdir -p "$APP/Contents/Resources/bin"
cp -R bin/. "$APP/Contents/Resources/bin/"
rm -rf "$APP/Contents/Resources/bin/__pycache__"
for ac in "../../agents/alexus-core/bin" "$HOME/Developer/alexus-core/bin"; do
  if [ -d "$ac" ]; then
    mkdir -p "$APP/Contents/Resources/alexus-core/bin"
    for f in fido-auth.sh ragnarok_bridge.py; do
      [ -f "$ac/$f" ] && cp "$ac/$f" "$APP/Contents/Resources/alexus-core/bin/"
    done
    break
  fi
done
# SwiftPM does not run Xcode's ExtractAppIntentsMetadata phase. Extract the
# shared intent declarations under the app's module name so the system can route
# a control to the containing app. This object is for metadata only, never linked.
META="$PWD/build/control-metadata"; mkdir -p "$META"
printf '%s\n' '["AppEnum","AppIntent"]' > "$META/protocols.json"
printf '%s\n' "$PWD/Sources/Heimdall/ControlIntents.swift" > "$META/sources"
printf '%s\n' "$META/ControlIntents.swiftconstvalues" > "$META/const-values"
xcrun swiftc -module-name Heimdall -D RAGNAROK_CONTROLS_EXTENSION -parse-as-library \
  -emit-object -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend "$META/protocols.json" \
  -module-cache-path "$PWD/.build/ModuleCache" Sources/Heimdall/ControlIntents.swift -o "$META/ControlIntents.o"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name Heimdall --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macosx14.0" \
  --source-file-list "$META/sources" --swift-const-vals-list "$META/const-values"
test -s "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
# App icon: Resources/AppIcon.png if present, else render Resources/AppIcon.svg (Quick Look). Never fails the build.
make_icon() {
  T=$(mktemp -d); SRC=Resources/AppIcon.png
  if [ ! -f "$SRC" ]; then
    qlmanage -t -s 1024 -o "$T" Resources/AppIcon.svg >/dev/null 2>&1 || return 1
    SRC="$T/AppIcon.svg.png"; [ -f "$SRC" ] || return 1
  fi
  mkdir -p "$T/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null || return 1
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null || return 1
  done
  iconutil -c icns "$T/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || return 1
  rm -rf "$T"
}
make_icon || echo "warning: app icon not built; continuing without it"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ragnarok</string>
  <key>CFBundleDisplayName</key><string>Ragnarok</string>
  <key>CFBundleIdentifier</key><string>co.rgnrk.heimdall</string>
  <key>CFBundleExecutable</key><string>Heimdall</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>co.rgnrk.heimdall</string>
    <key>CFBundleURLSchemes</key><array><string>ragnarok</string><string>ragnarok-cc</string></array>
  </dict></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Ragnarok reads activity from and chats with Alexus on your home network.</string>
  <key>NSFaceIDUsageDescription</key><string>Unlock Ragnarok with Touch ID.</string>
  <key>NSMicrophoneUsageDescription</key><string>Talk to Home Assistant's Assist from the Home tab.</string>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :ALEXUSSourceRoot string $ALEXUS_ROOT" "$APP/Contents/Info.plist"
# Money → Receipts and the Home Assistant tab show plain-http pages from Alexus in a WKWebView. App Transport Security
# blocks plain http to the Tailscale address (the home-network address is already allowed), so allow it for that one
# address only (ALEXUS_TAILSCALE from ~/.ragnarok/local.conf, default "alexus"). Nothing else is loosened.
TS_HOST=$(. bin/local-config.sh && printf '%s' "$ALEXUS_TAILSCALE")
case "$TS_HOST" in *:*) echo "note: ALEXUS_TAILSCALE looks like IPv6; no ATS exception added" ;; *)
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" \
  -c "Add :NSAppTransportSecurity:NSExceptionDomains:$TS_HOST dict" \
  -c "Add :NSAppTransportSecurity:NSExceptionDomains:$TS_HOST:NSExceptionAllowsInsecureHTTPLoads bool true" "$APP/Contents/Info.plist" ;;
esac
# The Browser tab is a general web browser, so its web view may load plain-http pages too. This key only loosens
# WKWebView content; the app's own network calls keep the rule above (one Tailscale exception).
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent bool true" "$APP/Contents/Info.plist"
# Control Center tiles: build the extension, put it in the app, sign inside-out (ad-hoc fallback: no tiles)
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN" && command -v xcodegen >/dev/null; then
  rm -rf Controls/.xbuild/Release/RagnarokControls.appex   # report item 29: never ship tiles left over from an older build
  ( set +e; cd Controls && xcodegen generate --quiet && xcodebuild -project RagnarokControls.xcodeproj -scheme RagnarokControls \
      -derivedDataPath "$PWD/.xbuild/DerivedData" -configuration Release CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/.xbuild" build -quiet 2>&1 | grep -vE 'CoreSimulator|SimServiceContext|DVTErrorPresenter|Recovery Suggestion|Code: 3|^$'
    exit "${PIPESTATUS[0]}" ) && tiles=ok || tiles=failed
  if [ "$tiles" = ok ] && [ -d Controls/.xbuild/Release/RagnarokControls.appex ]; then
    mkdir -p "$APP/Contents/PlugIns"
    cp -R Controls/.xbuild/Release/RagnarokControls.appex "$APP/Contents/PlugIns/"
    codesign --force --timestamp=none -s "$SIGN" --entitlements Controls/Controls.entitlements "$APP/Contents/PlugIns/RagnarokControls.appex"
  else
    echo "note: the Control Center tiles didn't build; this build has no tiles"
  fi
  codesign --force --timestamp=none -s "$SIGN" "$APP/Contents/Resources/EnclaveAuthenticator"
  codesign --force --timestamp=none -s "$SIGN" "$APP"
else
  echo "note: signing identity or xcodegen missing; ad-hoc signed, without the Control Center tiles"
  codesign --force -s - "$APP/Contents/Resources/EnclaveAuthenticator"
  codesign --force -s - "$APP"
fi
echo "built $APP"
# --install: put this build in place as the current one (first setup, or by hand). Normal edits go through bin/heimdall-edit.
if [ "${1:-}" = --install ]; then
  S="$HOME/Library/Application Support/Heimdall"; mkdir -p "$S"
  rm -rf "$S/incoming.app" "$S/previous.app"; cp -R "$APP" "$S/incoming.app"
  C="$HOME/Applications/Ragnarok.app"
  # refresh in place (the folder stays, so Dock icons keep working); the old build is kept as a copy
  [ -d "$C" ] && cp -R "$C" "$S/previous.app"
  mkdir -p "$C" && rsync -a --delete --ignore-times "$S/incoming.app/" "$C/" && rm -rf "$S/incoming.app"; date +%s > "$S/installed-at"
  # tell the running app (Timeline tab shows "New build ready" + Restart), the same file bin/heimdall-edit writes
  dirty=""; git diff --quiet HEAD 2>/dev/null || dirty=" (with uncommitted changes)"
  printf '%s\n%s\n' "$(cat "$C/Contents/Resources/commit")" "installed by make-app.sh --install$dirty" > "$S/update-ready"
  echo "installed as $C"
fi
