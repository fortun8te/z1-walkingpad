# Z1 WalkingPad

Control a KingSmith WalkingPad Z1 under-desk treadmill from a Mac over Bluetooth LE — start/stop, speed control, live distance/steps/calories — via a Python core library, a CLI, an MCP server, or a native macOS menu-bar app. Built specifically for the Z1 (advertises as `KS-HD-Z1D`, firmware V0.0.6), but the protocol likely covers other `KS-HD-*` KingSmith devices.

## Repository layout

The project is layered around a shared BLE core; every frontend is an optional, independent install:

```
src/z1_walkingpad_mcp/
  ├── protocol.py/constants.py   Core: frame builders/parsers, UUIDs, opcodes
  ├── client.py                  Core: Z1Treadmill async BLE client
  ├── metrics.py                 Core: MET-based calorie estimation
  ├── cli.py                     Frontend: command line
  └── server.py                  Frontend: MCP server (extra: pip install .[mcp])
macos/                        Frontend: native macOS menu-bar app (Swift, independent build)
docs/protocol.md              Byte-level wire spec (the contract both implementations follow)
docs/reverse-engineering.md   How the protocol was cracked — full story incl. dead ends
scripts/                      The BLE reverse-engineering record (incl. the winning replay)
tests/                        Unit tests (no BLE needed)
```

The macOS app implements the same protocol independently in Swift — it shares nothing with the Python side except the spec, so you can build and use it without installing any Python tooling (and vice versa).

## How it works

### The unlock gate (the important part)

The Z1 speaks standard Bluetooth SIG **FTMS** (Fitness Machine Service, `0x1826`) for control and telemetry — but **everything is gated behind a vendor unlock handshake** on the KingSmith supplement service (`24e2521c-…-c5330a00fdf7`). Until the unlock frame lands:

- every FTMS Control Point (`0x2AD9`) write is silently ignored (the write acks, but there's no indication and no action — start/stop produce only a beep), and
- the pad emits **zero** notifications on any characteristic.

This is why naive FTMS clients — including the `walkingpad-controller` library, which is confirmed working on other Z1 units — connect fine but can do nothing. There is no bonding, no pairing, no MTU requirement: the name-derived unlock token is the entire auth mechanism. (The KS Fit app is explicitly *anti*-pairing; its troubleshooting text tells users to unpair the treadmill from OS Bluetooth settings.)

The full unlock sequence:

1. Subscribe the supplement **notify** characteristic (`…b00fdf7`) **before writing anything**
2. Write the unlock frame to `…d00fdf7` **without response** (some firmware silently drops write-with-response here):
   `71 00 05 01 <T> CC` where `T = LE32(last 4 chars of BLE name) + 1` and `CC = sum(all prior bytes) & 0xFF`.
   For `KS-HD-Z1D`: last4 = `-Z1D` → `T = 2E 5A 31 44` → the exact frame is **`71 00 05 01 2e 5a 31 44 74`**
3. The pad replies `71 80` on the notify characteristic (usually <100 ms) → unlocked
4. Optional session init: `SYS_INFO` (`71 01 08 <unix-time LE32> <user-id LE32> CC` → `71 81`), `SETTING_GET` (`72 00 01 00 73` → `72 80` property dump)
5. From here FTMS behaves like the textbook spec, and telemetry notifications flow

### GATT map

| UUID | Props | Purpose |
|---|---|---|
| `00001826-…` | service | standard FTMS fitness machine service |
| `00002acc-…` | read | fitness machine features |
| `00002ad4-…` | read | supported speed range → **1.6–6.4 km/h** (0.1 steps) |
| `00002acd-…` | notify | treadmill data (live telemetry, ~1 frame/sec while running) |
| `00002ada-…` | notify | fitness machine status (started/stopped events) |
| `00002ad9-…` | write, indicate | **FTMS control point** (start/stop/speed) |
| `24e2521c-…-c5330a00fdf7` | service | KingSmith supplement service (the gate) |
| `24e2521c-…-c5330b00fdf7` | notify | supplement read channel |
| `24e2521c-…-c5330d00fdf7` | write, write-no-rsp | supplement write channel |
| `0000180a-…` | service | device information (firmware `V0.0.6`) |
| `0xFFC0` / `0xFFF0` / `0xFF00` | — | JieLi-chip OTA — **do not touch** |

### Vendor (supplement) frames

```
[cmd0, cmd1, len, data[len], checksum]     checksum = sum(all prior bytes) & 0xFF
```

- All writes go to `…d00fdf7` as **write without response**, paced **≥400 ms** apart (faster writes are dropped)
- Responses arrive on the `…b00fdf7` notify characteristic; ~3 s timeout
- Unlock: `71 00 05 01 <T> CC` → `71 80` (success)
- SYS_INFO: `71 01 08 <ts LE32> <uid LE32> CC` → `71 81` (protocol version, model, caps)
- Property read all: `72 00 01 00 73` → `72 80`, data = 4-byte records `[id, error, valLo, valHi]` (u16 LE)
- Property write: `72 01 03 <id> <lo> <hi> CC` → `72 81` (`data[1]=0` = OK)
- Unsolicited: property pushes `72 50` (3-byte records), exercise-record events `73 50`, fault records `73 51`
- **Never** send frames starting with `0xE8` (OTA mode — brick risk)

Properties observed on the Z1: `1` units/language, `2` auto-stop (bit15 enabled, low bits seconds), `4` motor version, `5` last error, `6` child lock, `8` switches (buzzer, interaction light), `10` device mode (manual/auto/sleep).

### FTMS control (post-unlock)

Control point `0x2AD9`, write **with** response, pace ≥400 ms. Every command answers an indication `[0x80, request-op, result, params…]` — result `1` = success, `5` = control not permitted (re-send `00` and retry once).

| Op | Bytes | Effect |
|---|---|---|
| Request Control | `00` | required once before any command |
| Start/Resume | `07` | belt ramps to minimum speed (1.6 km/h) |
| Set Target Speed | `02 <u16 LE, km/h×100>` | e.g. 2.5 km/h = `02 fa 00` |
| Stop / Pause | `08 01` / `08 02` | |

A typical session: `00` → `07` → `02 …` (as often as you like) → `08 01`.

### Telemetry

Standard FTMS treadmill data on `0x2ACD`: flags u16 LE, then fields in flag order. The Z1 sends flags `0x2404` — distance (bit 2, u24 meters), elapsed time (bit 10, u16 seconds), **step count (bit 13, u16 — KingSmith extension)** — plus instantaneous speed (flag bit 0 clear, u16 km/h×100). Distance/steps accumulate under load; counters persist across BLE connections, so clients snapshot a baseline at session start and compute deltas.

### What the pad does NOT provide

- **Calories / heart rate** — no HR sensor, and the telemetry never sets the energy bit. Calories are computed locally (see Health metrics below).
- **Display/screen control** — the LED panel cycling is not exposed over BLE at all (even the working duttke.de implementation throws `"FTMS does not expose panel-display configuration"` for this device family). The remote's display button talks RF directly to the pad.
- **Incline** — fixed hardware.

### How this was found

Static reverse engineering under constraints (no official-app install, no extra hardware): blutter disassembly of the KS Fit Android app, upstream issue archaeology, and the breakthrough — the [duttke.de Web Bluetooth implementation](https://www.duttke.de/en/walkingpad/), whose unlock frame variant is the one firmware V0.0.6 accepts. Full story with the dead ends: **`docs/reverse-engineering.md`**. Byte-level spec: **`docs/protocol.md`**.

## Usage

### Install (Python)

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev,mcp]"   # drop ",mcp" for core+CLI only
```

### CLI

```bash
.venv/bin/python -m z1_walkingpad_mcp status                    # connect, unlock, dump properties
.venv/bin/python -m z1_walkingpad_mcp start --speed 2.5         # start belt, set 2.5 km/h
.venv/bin/python -m z1_walkingpad_mcp start --duration 30       # auto-stop after 30 s
.venv/bin/python -m z1_walkingpad_mcp up --delta 0.2            # nudge speed up (default 0.1)
.venv/bin/python -m z1_walkingpad_mcp down                      # nudge speed down
.venv/bin/python -m z1_walkingpad_mcp stop                      # stop + session summary
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

### macOS menu-bar app (optional, independent)

A native SwiftUI menu-bar app — start/stop, speed steppers, live distance/steps/calories — lives in `macos/`:

```bash
cd macos && bash build-app.sh --install   # builds Z1WalkingPad.app, copies to /Applications
```

See `macos/README.md`. Only one BLE connection at a time: quit the app (or the MCP server) before using the other.

### Tests

```bash
.venv/bin/python -m pytest tests/    # 17 tests, no BLE needed
```

## Health metrics

The pad streams speed, distance, elapsed time, and steps live. Calories are computed locally with the **ACSM walking metabolic equation** (the exercise-physiology standard for level walking): `VO2 = 0.1 × speed(m/min) + 3.5` ml/kg/min, then `kcal/min = VO2 × weight_kg / 200`. Chosen over the Compendium MET table on research grounds — the fixed MET buckets misclassify intensity at slow walking speeds; expect ±10–15% real-world error. Set your weight for accurate numbers:

```bash
export Z1_WEIGHT_KG=80   # default is 75; the macOS app has its own weight setting
```

`treadmill_stop` (and the CLI `stop`) returns a session summary — duration, distance, steps, average speed, estimated calories — and the MCP server appends it to `~/.z1-walkingpad/sessions.jsonl`.

**Apple Health:** HealthKit does not exist on macOS, so a Mac client cannot write to Apple Health directly — KS Fit does it from the iPhone. The session history file is the bridge: import it with an iOS Shortcut ("Log Workout"/"Log Health Sample" actions), or any Health-import app that reads CSV/JSON.

## Safety model

| Operation | Mutating? | Notes |
|---|---|---|
| Scan / connect / read / notify | No | Unlock is a no-op auth handshake, not a command |
| Request Control (`0x00` write) | Yes (control claim) | Required before any command; does not move belt |
| Start / Stop / Pause / Set Speed | Yes | Only ever sent deliberately |

The pad allows one BLE connection at a time; close the phone app before connecting.
