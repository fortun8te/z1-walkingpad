#!/bin/bash
# Local release server. Serves macos/release/dist on 127.0.0.1:8741.
set -euo pipefail
DIST="$(cd "$(dirname "$0")" && pwd)/dist"
PORT="${Z1_RELEASE_PORT:-8741}"
mkdir -p "$DIST"
cd "$DIST"
if [[ ! -f latest.json ]]; then
  echo "no latest.json yet — run: bash macos/release/publish.sh" >&2
fi
echo "==> Z1 release server  http://127.0.0.1:${PORT}/latest.json"
exec python3 - "$PORT" <<'PY'
import sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args):
        sys.stderr.write("z1-release: " + (fmt % args) + "\n")
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

port = int(sys.argv[1])
httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
httpd.serve_forever()
PY
