# Z1 WalkingPad MCP

Control a KingSmith WalkingPad Z1 under-desk treadmill from a Mac over Bluetooth LE — CLI and MCP server. Built specifically for the Z1 (advertises as `KS-HD-Z1D`, firmware V0.0.6).

## How the protocol actually works (discovered 2026-07-30)

The Z1 speaks standard Bluetooth SIG **FTMS** (`0x1826`) for control/telemetry, **gated by a vendor unlock handshake** on the KingSmith supplement service (`24e2521c-…-c5330a00fdf7`). Until the unlock lands, the pad silently ignores every FTMS Control Point write and suppresses **all** notifications — this is why naive FTMS clients (and `walkingpad-controller`) connect fine but can do nothing.

Unlock sequence (see `src/z1_walkingpad_mcp/protocol.py`):

1. Subscribe the supplement **notify** char (`…b00fdf7`) **before writing anything**
2. Write the unlock frame to `…d00fdf7` **without response**: `71 00 05 01 <code LE32> CC` where code = `LE32(last 4 chars of BLE name) + 1`, CC = byte-sum checksum. For `KS-HD-Z1D`: `71 00 05 01 2e 5a 31 44 74`
3. Pad replies `71 80` on the notify char → unlocked; then `SYS_INFO` (`71 01 …`) and `SETTING_GET` (`72 00 …`) work
4. From here FTMS behaves normally: Request Control `00` → Start `07` → Set Speed `02 <km/h×100 LE>` → Stop `08 02`, with indications `80 <op> 01`

Vendor frames need ≥400 ms spacing; the firmware drops faster writes. No bonding, no MTU games (the KS Fit app is explicitly *anti*-pairing: the name-derived token is the auth).

Note: KS Fit (v5.9.10, blutter RE) uses a different request frame for the same handshake — `E2 00 0A RR <BE32(name[-4:])+RR as LE> CC` — and also receives `71 80` back. The Z1 firmware V0.0.6 accepts the `0x71` variant used by the [duttke.de Web Bluetooth implementation](https://www.duttke.de/en/walkingpad/), which is what this project implements.

## Usage

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev,mcp]"

# CLI
.venv/bin/python -m z1_walkingpad_mcp status                    # connect, unlock, dump properties
.venv/bin/python -m z1_walkingpad_mcp start --speed 2.5         # start belt, set 2.5 km/h
.venv/bin/python -m z1_walkingpad_mcp start --duration 30       # auto-stop after 30 s
.venv/bin/python -m z1_walkingpad_mcp up --delta 0.2            # nudge speed up
.venv/bin/python -m z1_walkingpad_mcp down                      # nudge speed down (0.1)
.venv/bin/python -m z1_walkingpad_mcp stop                      # stop + session summary

# tests (no BLE needed)
.venv/bin/python -m pytest tests/
```

### MCP server

```bash
.venv/bin/python -m z1_walkingpad_mcp.server    # stdio transport
```

Tools: `treadmill_status`, `treadmill_start`, `treadmill_set_speed`, `treadmill_speed_up`, `treadmill_speed_down`, `treadmill_pause`, `treadmill_stop`. Example client config:

```json
{
  "mcpServers": {
    "z1-walkingpad": {
      "command": "/path/to/z1-walkingpad-mcp/.venv/bin/python",
      "args": ["-m", "z1_walkingpad_mcp.server"]
    }
  }
}
```

## Health metrics

The pad streams speed, distance, elapsed time, and steps live (`0x2ACD`, including the KingSmith step-count extension). It does **not** report calories or heart rate — no HR sensor, and the telemetry flags never set the energy bit. Calories are computed locally exactly like fitness apps do: Compendium-of-Physical-Activities MET values for level walking, `kcal/min = MET × 3.5 × weight_kg / 200`. Set your weight for accurate numbers:

```bash
export Z1_WEIGHT_KG=80   # default is 75
```

`treadmill_stop` (and the CLI `stop`) returns a session summary — duration, distance, steps, average speed, estimated calories — and the MCP server appends it to `~/.z1-walkingpad/sessions.jsonl`.

**Apple Health:** HealthKit does not exist on macOS, so a Mac client cannot write to Apple Health directly — KS Fit does it from the iPhone. The session history file is the bridge: import it with an iOS Shortcut ("Log Workout"/"Log Health Sample" actions), or any Health-import app that reads CSV/JSON.

**Display cycling:** not possible over BLE. The Z1's firmware does not expose panel-display control (the working duttke.de implementation throws `"FTMS does not expose panel-display configuration"` for this device family — display control exists only on the legacy WiLink protocol). The remote's display button talks RF directly to the pad.

## Hardware findings

- Device: **WalkingPad Z1**, advertises as `KS-HD-Z1D`, firmware V0.0.6, speed range 1.6–6.4 km/h (0.1 steps)
- FTMS characteristics: `0x2AD9` control point (write/indicate), `0x2ACD` treadmill data (notify), `0x2AD4` speed range, `0x2ADA` machine status
- KingSmith extensions: step count in FTMS flags bit 13; supplement service carries unlock, properties (child lock, mode, auto-stop, …), exercise/fault events (`73 50`/`73 51`)
- Vendor services `0xFFC0`/`0xFFF0` look like JieLi-chip OTA — untouched; **never** send `E8 …` frames (OTA mode, brick risk)

## Safety model

| Operation | Mutating? | Notes |
|---|---|---|
| Scan / connect / read / notify | No | Unlock is a no-op auth handshake, not a command |
| Request Control (`0x00` write) | Yes (control claim) | Required before any command; does not move belt |
| Start / Stop / Pause / Set Speed | Yes | Only ever sent deliberately |

The pad allows one BLE connection at a time; close the phone app before connecting.
