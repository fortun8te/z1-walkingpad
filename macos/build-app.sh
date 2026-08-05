#!/bin/bash
# Build Z1WalkingPad.app from the Z1MenuBar executable.
#
#   bash macos/build-app.sh             build + ad-hoc sign into macos/Z1WalkingPad.app
#   bash macos/build-app.sh --install   also copy to /Applications
set -euo pipefail

cd "$(dirname "$0")"
APP="Z1WalkingPad.app"

echo "==> swift build -c release --arch arm64 (Z1MenuBar)"
swift build -c release --arch arm64 --product Z1MenuBar
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Z1MenuBar" "$APP/Contents/MacOS/Z1WalkingPad"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Z1WalkingPad</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.z1walkingpad.menubar</string>
    <key>CFBundleName</key>
    <string>Z1 WalkingPad</string>
    <key>CFBundleDisplayName</key>
    <string>Z1 WalkingPad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Z1 WalkingPad uses Bluetooth to connect to and control your KingSmith WalkingPad Z1 treadmill.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> done: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> installing to /Applications"
    cp -R "$APP" /Applications/
    echo "==> installed: /Applications/$APP"
fi
