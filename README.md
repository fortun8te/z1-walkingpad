# Z1 WalkingPad

Native **macOS** control for the KingSmith WalkingPad Z1 (`KS-HD-Z1D`), plus a read-only Python **MCP** stats server. The pad speaks Bluetooth FTMS (`0x1826`) behind a vendor unlock. This repo documents that handshake and keeps physical control in the native app.

**Search:** kingsmith walkingpad z1 mac, walkingpad bluetooth FTMS, under-desk treadmill macOS, walkingpad CLI, walkingpad MCP.

## macOS app

```bash
git clone https://github.com/fortun8te/z1-walkingpad.git
cd z1-walkingpad/macos
bash build-app.sh                 # builds dist/Z1WalkingPad.app, installs nothing
open dist/Z1WalkingPad.app
```

A small window app with a Dock icon. One BLE central at a time: quit KS Fit first.

See [macos/README.md](macos/README.md).

## Read-only Python MCP

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev,mcp]"
.venv/bin/python -m z1_walkingpad_mcp.server   # read-only tool z1(q=today|live|all|list)
```

The `z1-walkingpad` and `z1-walkingpad-mcp` commands both start this read-only MCP server. The former Python control CLI and web dashboard are retired. Retired control tests are preserved under `docs/legacy-python-tests/`; hardware scripts are excluded from test discovery.

Protocol notes live in [docs/protocol.md](docs/protocol.md). Do not send `0xE8` frames (OTA).

## License

MIT. See [LICENSE](LICENSE).

## Current tests

`cd macos && swift run z1tests` runs the Swift assertions with fake transports.
For Python, run `.venv/bin/python -m pytest -q`. The default suite covers all supported Python modules and excludes archived hardware experiments.
