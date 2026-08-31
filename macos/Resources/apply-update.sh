#!/bin/bash
# Replace the installed app after the running process has quit, then reopen.
# Args: <staged .app> <destination .app> <pid to wait for>
set -euo pipefail
FROM="${1:?}"
TO="${2:?}"
PID="${3:?}"

for _ in $(seq 1 200); do
  if ! /bin/kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
sleep 0.15

if [[ ! -d "$FROM/Contents/MacOS" ]]; then
  echo "z1-update: staged app missing" >&2
  exit 1
fi

IDENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FROM/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$IDENT" != "dev.z1walkingpad.menubar" ]]; then
  echo "z1-update: refused identifier '$IDENT'" >&2
  exit 1
fi

mkdir -p "$(dirname "$TO")"
/usr/bin/ditto --norsrc "$FROM" "$TO"
/usr/bin/xattr -cr "$TO" 2>/dev/null || true
/usr/bin/open "$TO"
