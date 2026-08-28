#!/bin/bash
# Build Z1WalkingPad.app from the Z1MenuBar executable.
#
# Sign with a stable identity so Bluetooth TCC is not re-prompted on rebuild.
# Install by ditto into the existing /Applications bundle in place — do not
# rm -rf the destination, or TCC treats it as a new app.
#
#   bash macos/build-app.sh                build, sign, install to /Applications
#   bash macos/build-app.sh --no-install   leave the bundle in macos/ instead
set -euo pipefail

cd "$(dirname "$0")"
APP="Z1WalkingPad.app"
ENTITLEMENTS="Sources/Z1MenuBar/Z1WalkingPad.entitlements"

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
    <string>20260826</string>
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

# Ad-hoc only. A named identity exists on this Mac but the keychain cannot
# sign with it (errSecInternalComponent) and there is no Apple Developer ID.
# Bluetooth TCC stays put because we keep the same bundle id + install in
# place instead of deleting /Applications/Z1WalkingPad.app.
echo "==> ad-hoc codesign (stable bundle id + in-place install)"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
    echo "==> done (not installed): $(pwd)/$APP"
    exit 0
fi

if pgrep -f "/Applications/$APP" >/dev/null 2>&1; then
    echo "==> quitting the running copy"
    pkill -f "/Applications/$APP" || true
    sleep 1
fi

echo "==> installing to /Applications (in-place ditto; keep TCC path + identity)"
mkdir -p "/Applications/$APP"
ditto "$APP" "/Applications/$APP"
rm -rf "$APP"   # one copy on this machine, and it is the installed one

echo "==> verifying installed signature"
codesign -dv --verbose=4 "/Applications/$APP"
IDENT="$(codesign -d --verbose=2 "/Applications/$APP" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$IDENT" != "dev.z1walkingpad.menubar" ]]; then
    echo "error: expected identifier dev.z1walkingpad.menubar, got: $IDENT" >&2
    exit 1
fi
echo "==> identifier: $IDENT"
echo "==> installed: /Applications/$APP"
