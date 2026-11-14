#!/bin/bash
# make-launcher.sh: build the hidden launcher helper (run once; edits never change it).
# Ragnarok is one app: ~/Applications/Ragnarok.app (the Dock icon). Opening it hands off to this helper,
#   ~/Library/Application Support/Heimdall/Ragnarok Launcher.app  (LSUIElement: no Dock icon, no menu bar)
# which runs the app, restarts it on crash and rolls back bad builds (launcher/heimdall-launcher).
set -eu
cd "$(dirname "$0")"
L="$HOME/Library/Application Support/Heimdall/Ragnarok Launcher.app"
rm -rf "$L"; mkdir -p "$L/Contents/MacOS" "$L/Contents/Resources"
ICNS="$HOME/Applications/Ragnarok.app/Contents/Resources/AppIcon.icns"
[ -f "$ICNS" ] && cp "$ICNS" "$L/Contents/Resources/AppIcon.icns"
cp launcher/heimdall-launcher "$L/Contents/MacOS/heimdall-launcher"; chmod +x "$L/Contents/MacOS/heimdall-launcher"
cat > "$L/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ragnarok Launcher</string>
  <key>CFBundleIdentifier</key><string>co.rgnrk.heimdall.launcher</string>
  <key>CFBundleExecutable</key><string>heimdall-launcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$L"
echo "built $L"
