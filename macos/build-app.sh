#!/bin/bash
# Build Z1WalkingPad.app from the Z1MenuBar executable.
#
# Silent re-sign: same bundle id, in-place ditto, no repeated dialogs.
# Running session continues: graceful quit leaves belt moving, auto-reconnect on next launch restores counters via sessionStore + calorieState.
#   bash macos/build-app.sh                build, sign, install to /Applications
#   bash macos/build-app.sh --no-install   leave the bundle in macos/
#   bash macos/build-app.sh --quiet        suppress chatter (for resign loops)
set -euo pipefail

cd "$(dirname "$0")"
APP="Z1WalkingPad.app"
ENTITLEMENTS="Sources/Z1MenuBar/Z1WalkingPad.entitlements"
QUIET=0
NO_INSTALL=0
for arg in "${@:-}"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    --no-install) NO_INSTALL=1 ;;
  esac
done
qecho() { [[ $QUIET -eq 1 ]] || echo "$@"; }
qecho "==> swift build -c release --arch arm64 (Z1MenuBar)"
# Build quietly unless --quiet not set; tee to log for errors
LOG=$(mktemp -t z1build.XXXXXX)
if ! swift build -c release --arch arm64 --product Z1MenuBar --disable-sandbox >"$LOG" 2>&1; then
  cat "$LOG" >&2; rm -f "$LOG"; exit 1
fi
[[ $QUIET -eq 1 ]] || cat "$LOG" | tail -n 20
rm -f "$LOG"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path --disable-sandbox 2>/dev/null)"

qecho "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Z1MenuBar" "$APP/Contents/MacOS/Z1WalkingPad"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Remove quarantine so Gatekeeper doesn't nag after ad-hoc resign
xattr -cr "$APP" 2>/dev/null || true

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
    <string>20260828</string>
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

# Ad-hoc, timestamp none, runtime hardened off — keeps TCC stable, no network.
# Suppress output when --quiet
qecho "==> ad-hoc codesign (stable bundle id + in-place, silent)"
if [[ $QUIET -eq 1 ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none --options runtime "$APP" >/dev/null 2>&1
else
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none --options runtime "$APP"
fi
# Also strip quarantine again after sign (signing can re-add)
xattr -cr "$APP" 2>/dev/null || true

if [[ $NO_INSTALL -eq 1 ]]; then
    qecho "==> done (not installed): $(pwd)/$APP"
    exit 0
fi

# Graceful replace that keeps running walk alive:
# - If running, try AppleScript quit (triggers cancelConnectionNow, belt stays moving, session persisted)
# - Wait up to 5s, only then pkill. Data on disk already flushed per-second + throttled.
if pgrep -f "/Applications/$APP" >/dev/null 2>&1; then
    qecho "==> quitting running copy (graceful, belt stays moving)"
    osascript -e 'tell application "Z1WalkingPad" to quit' >/dev/null 2>&1 || true
    for i in 1 2 3 4 5; do
      pgrep -f "/Applications/$APP" >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f "/Applications/$APP" >/dev/null 2>&1; then
      qecho "==> fallback pkill"
      pkill -f "/Applications/$APP" || true
      sleep 1
    fi
fi

qecho "==> installing to /Applications (in-place ditto; keeps TCC & session)"
mkdir -p "/Applications/$APP"
# Ditto preserves TCC identity; --noqtn avoids quarantine flag
ditto --noqtn "$APP" "/Applications/$APP" 2>/dev/null || ditto "$APP" "/Applications/$APP"
xattr -cr "/Applications/$APP" 2>/dev/null || true
rm -rf "$APP"

if [[ $QUIET -eq 0 ]]; then
  echo "==> verifying signature"
  codesign -dv --verbose=0 "/Applications/$APP" 2>&1 | head -n 20
fi
IDENT="$(codesign -d --verbose=2 "/Applications/$APP" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$IDENT" != "dev.z1walkingpad.menubar" ]]; then
    echo "error: expected identifier dev.z1walkingpad.menubar, got: $IDENT" >&2
    exit 1
fi
qecho "==> identifier: $IDENT"
qecho "==> installed: /Applications/$APP (session continues on relaunch — agent-data & sessions.json retained)"
