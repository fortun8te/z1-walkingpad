#!/bin/bash
# Build Z1WalkingPad.app into macos/dist/. Nothing is installed, nothing is
# launched, no running copy is touched.
#
#   bash macos/build-app.sh            release build -> macos/dist/Z1WalkingPad.app
#   bash macos/build-app.sh --debug    debug build, faster, for UI work
#   bash macos/build-app.sh --quiet    less chatter
#   Z1_BUILD_SCRATCH=/private/tmp/z1-build bash macos/build-app.sh
#   Z1_DISABLE_SWIFT_SANDBOX=1         for an already sandboxed build host
#   Z1_BUILD_DIST=/private/tmp/z1-dist optional bundle output directory
#
# Version: CFBundleShortVersionString is 2.0 (Z1_SHORT_VERSION overrides it).
# CFBundleVersion is the minute of the build as yyyyMMddHHmm; builds in the
# same minute share a number (Z1_BUNDLE_VERSION overrides it). Settings
# and the About panel show both: "Z1 2.0 (build 202610131200)".
#
# Icon: Resources/AppIcon.icns is the app's icon (white Z1 on red). It is the
# only icon the build uses; replace that file to change it.
#
# The bundle id stays dev.z1walkingpad.menubar on purpose: settings, the
# remembered pad, the open-walk tracker and the Bluetooth permission all hang
# off it. To use the build, quit the old app and copy the bundle to
# /Applications yourself.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Z1WalkingPad"
BUNDLE_ID="dev.z1walkingpad.menubar"
DIST="${Z1_BUILD_DIST:-dist}"
OUTPUT_APP="$DIST/$APP_NAME.app"
SCRATCH="${Z1_BUILD_SCRATCH:-.build-frontend}"
ENTITLEMENTS="Sources/Z1App/Z1WalkingPad.entitlements"
CONFIG="release"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    --debug) CONFIG="debug" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
say() { [[ $QUIET -eq 1 ]] || echo "$@"; }

# No usable Xcode (not installed, or licence not accepted): build with the
# Command Line Tools and the newest macOS 26 SDK they ship. `xcodebuild
# -version` still succeeds with the licence unaccepted, so probe the
# toolchain itself too.
if ! xcodebuild -version >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  CLT=/Library/Developer/CommandLineTools
  SDK="$(ls -d "$CLT"/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$SDK" ]]; then
    export DEVELOPER_DIR="$CLT"
    export SDKROOT="$SDK"
    say "==> Xcode unavailable; using $CLT with $(basename "$SDK")"
  fi
fi

BUILD=(swift build -c "$CONFIG" --arch arm64 --product Z1App --scratch-path "$SCRATCH")
if [[ "${Z1_DISABLE_SWIFT_SANDBOX:-0}" == "1" ]]; then
  BUILD+=(--disable-sandbox)
fi
say "==> ${BUILD[*]}"
LOG=$(mktemp -t z1build.XXXXXX)
if ! "${BUILD[@]}" >"$LOG" 2>&1; then
  cat "$LOG" >&2; rm -f "$LOG"; exit 1
fi
[[ $QUIET -eq 1 ]] || tail -n 3 "$LOG"
# A warning is never swallowed, even in a build that succeeds.
grep -A2 "warning:" "$LOG" >&2 || true
rm -f "$LOG"
BIN_DIR="$("${BUILD[@]}" --show-bin-path 2>/dev/null)"

VERSION="${Z1_BUNDLE_VERSION:-$(date +%Y%m%d%H%M)}"
SHORT="${Z1_SHORT_VERSION:-2.0}"

# Assemble and verify beside the destination, keeping the last usable build
# intact if copying resources or signing fails. Same-volume renames publish
# the result; retain the backup if a failed publish cannot be rolled back.
mkdir -p "$DIST"
STAGING=$(mktemp -d "$DIST/.z1-bundle.XXXXXX")
APP="$STAGING/$APP_NAME.app"
BACKUP="$STAGING/Previous.app"
cleanup_bundle() {
  if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
    if [[ ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]]; then
      mv "$BACKUP" "$OUTPUT_APP" || {
        echo "error: previous bundle retained at $BACKUP" >&2
        return
      }
    else
      echo "error: previous bundle retained at $BACKUP" >&2
      return
    fi
  fi
  rm -rf "$STAGING"
}
trap cleanup_bundle EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
say "==> bundling $OUTPUT_APP ($SHORT, build $VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Z1App" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Z1 WalkingPad</string>
    <key>CFBundleDisplayName</key>
    <string>Z1 WalkingPad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.healthcare-fitness</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Z1 WalkingPad uses Bluetooth to connect to and control your KingSmith WalkingPad Z1 treadmill.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the Bluetooth entitlement; no timestamp, no network.
say "==> ad-hoc codesign"
# Finder/iCloud metadata on generated files can make codesign reject an
# otherwise valid bundle. Remove it before signing, never after verification.
xattr -cr "$APP"
codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none --options runtime "$APP"
codesign --verify --deep --strict "$APP"

IDENT="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$IDENT" != "$BUNDLE_ID" ]]; then
  echo "error: expected identifier $BUNDLE_ID, got: $IDENT" >&2
  exit 1
fi
if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
  mv "$OUTPUT_APP" "$BACKUP"
fi
mv "$APP" "$OUTPUT_APP"
rm -rf "$BACKUP"
say "==> built $(cd "$DIST" && pwd)/$APP_NAME.app: Z1 $SHORT (build $VERSION)"
