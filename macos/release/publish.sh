#!/bin/bash
# Build a versioned zip + latest.json for the release server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$(cd "$(dirname "$0")" && pwd)/dist"
VERSION="${Z1_BUNDLE_VERSION:-$(date +%Y%m%d%H%M)}"
SHORT="${Z1_SHORT_VERSION:-1.0}"
NOTES="${Z1_RELEASE_NOTES:-}"
PORT="${Z1_RELEASE_PORT:-8741}"
BASE="http://127.0.0.1:${PORT}"
ZIP_NAME="Z1WalkingPad-${VERSION}.zip"

mkdir -p "$DIST"
export Z1_BUNDLE_VERSION="$VERSION"
export Z1_SHORT_VERSION="$SHORT"
bash "$ROOT/build-app.sh" --no-install --quiet

cd "$ROOT"
rm -f "$DIST/$ZIP_NAME"
ditto -c -k --keepParent Z1WalkingPad.app "$DIST/$ZIP_NAME"
rm -rf Z1WalkingPad.app
SHA="$(shasum -a 256 "$DIST/$ZIP_NAME" | awk '{print $1}')"

python3 - "$DIST/latest.json" "$VERSION" "$SHORT" "$BASE/$ZIP_NAME" "$SHA" "$NOTES" <<'PY'
import json, sys
path, version, short, url, sha, notes = sys.argv[1:7]
feed = {
    "version": version,
    "shortVersion": short,
    "url": url,
    "sha256": sha,
}
if notes:
    feed["notes"] = notes
with open(path, "w", encoding="utf-8") as f:
    json.dump(feed, f, indent=2)
    f.write("\n")
PY

# Keep the latest zip under a stable name so a pinned URL still works.
cp "$DIST/$ZIP_NAME" "$DIST/Z1WalkingPad-latest.zip"

# The running app serves this folder (and the repo dist) on :8741.
SUPPORT="${HOME}/Library/Application Support/Z1 WalkingPad/updates"
mkdir -p "$SUPPORT"
cp "$DIST/$ZIP_NAME" "$DIST/Z1WalkingPad-latest.zip" "$DIST/latest.json" "$SUPPORT/"

echo "==> published $VERSION"
echo "    $DIST/$ZIP_NAME"
echo "    sha256 $SHA"
echo "    feed   $BASE/latest.json"
echo "    the app starts the release server while it is running"
