#!/bin/bash
# make-app.sh: build Conveyor.app from this package into build/.
# Signed ad hoc, which runs on this Mac. Giving it to other people needs a
# Developer ID signature and notarization.
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=build/Conveyor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Conveyor "$APP/Contents/MacOS/Conveyor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Conveyor</string>
  <key>CFBundleIdentifier</key><string>co.rgnrk.conveyor</string>
  <key>CFBundleExecutable</key><string>Conveyor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
