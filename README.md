# Z1 WalkingPad

Native **macOS** control for the KingSmith WalkingPad Z1 (`KS-HD-Z1D`), plus a Python **CLI / MCP** client. The pad speaks Bluetooth FTMS (`0x1826`) behind a vendor unlock. This repo documents that handshake and ships two implementations.

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

## Python CLI / MCP

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev,mcp]"
.venv/bin/python -m z1_walkingpad_mcp start --speed 2.5
.venv/bin/python -m z1_walkingpad_mcp.server   # read-only tool z1(q=today|live|all|list)
```

Protocol notes live in [docs/protocol.md](docs/protocol.md). Do not send `0xE8` frames (OTA).

## License

MIT. See [LICENSE](LICENSE).
