# Z1 WalkingPad

Control a KingSmith WalkingPad Z1 under-desk treadmill from a Mac over Bluetooth LE — start/stop, speed control, live distance/steps/calories. Two independent frontends share one protocol:

- **macOS menu-bar app** (`macos/`) — a native SwiftUI app living in your menu bar, for daily driving
- **MCP server + CLI + Python library** (`src/`) — for AI assistants (Claude, Kimi, …), scripting, and automation

Built specifically for the Z1 (advertises as `KS-HD-Z1D`, firmware V0.0.6), but the protocol likely covers other `KS-HD-*` KingSmith devices.

## The two frontends

| | macOS menu-bar app | MCP server / CLI / Python lib |
|---|---|---|
| Purpose | Manual daily control | AI-assistant control (`treadmill_start`, …) and scripts |
| Code | Swift, CoreBluetooth (`macos/`) | Python, bleak (`src/z1_walkingpad_mcp/`) |
| Install | `cd macos && bash build-app.sh --install` | `uv pip install -e ".[mcp]"` |
| Units | Imperial/metric setting (default Imperial) | km/h + kg internally; `Z1_WEIGHT_KG` env |
| Session log | in-app summary | JSON files in `~/.z1-walkingpad/` (or `Z1_SESSIONS_DIR`) |
| Settings UI | units, body weight, speed step | env vars |

Both talk to the pad directly and independently — neither needs the other. **Only one BLE connection at a time**: quit the app (or stop the MCP server) before using the other.

## Behavior nuances (what to expect)

- **The pad is the master.** Belt state follows the treadmill itself, not our commands: start it with the physical remote and the app shows Stop + live speed in the menu bar anyway. State comes from three sources — telemetry speed, machine-status events, and our commands.
- **Start on a moving belt is a no-op** (the pad refuses it) — so `start()` skips the command when the belt is already moving.
- **Sessions resume within 10 minutes.** Stop → Start inside 10 min keeps accumulating calories/distance/time/steps; after that, a fresh session starts. (Speed still comes back at minimum — that's the pad, not us.)
- **Calories persist across reconnects.** Integration is client-side but saved every second; reconnect while the belt is still moving and the count continues — including an estimate for the disconnected gap.
- **Pad counters reset on Stop** (the pad finalizes its session) but persist across BLE connections while running — that's why distance/steps "come back" on reconnect.
- **Exit stops the belt and sleeps the pad** (standby mode), then quits — never hangs more than 3 s.
- **Battery:** unmeasurable. The app idles at 0.0% CPU / 0.0 power-impact score; BLE at one small packet per second is designed for coin-cell devices.
- **One user at a time:** the pad accepts a single BLE connection — if Connect spins forever, something else (phone app, the other frontend) is holding it.

## Usage

### macOS menu-bar app

```bash
cd macos && bash build-app.sh --install   # builds + ad-hoc signs Z1WalkingPad.app, copies to /Applications
```

Click the `figure.walk` icon in the menu bar → Connect. Big speed readout with −/+ steppers, Start/Stop, live elapsed/distance/steps/kcal grid, last-session line. Settings (expandable): Imperial/Metric (also syncs the pad's own LED units), body weight, speed per −/+ tap. Exit stops the belt and sleeps the pad.

Details: `macos/README.md`.

### Python install + CLI

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev,mcp]"   # drop ",mcp" for core+CLI only

.venv/bin/python -m z1_walkingpad_mcp status                    # connect, unlock, dump properties
.venv/bin/python -m z1_walkingpad_mcp start --speed 2.5         # start belt, set 2.5 km/h
.venv/bin/python -m z1_walkingpad_mcp start --duration 30       # auto-stop after 30 s
.venv/bin/python -m z1_walkingpad_mcp up --delta 0.2            # nudge speed up (default 0.1)
.venv/bin/python -m z1_walkingpad_mcp down                      # nudge speed down
.venv/bin/python -m z1_walkingpad_mcp stop                      # stop + session summary

.venv/bin/python -m pytest tests/    # unit tests, no BLE needed
```

### MCP server (for AI assistants)

```bash
.venv/bin/python -m z1_walkingpad_mcp.server    # stdio transport
```

Tools: `treadmill_status`, `treadmill_start`, `treadmill_set_speed`, `treadmill_speed_up`, `treadmill_speed_down`, `treadmill_pause`, `treadmill_stop`. Example client config:

```json
{
  "mcpServers": {
    "z1-walkingpad": {
      "command": "/path/to/z1-walkingpad-mcp/.venv/bin/python",
      "args": ["-m", "z1_walkingpad_mcp.server"],
      "env": { "Z1_WEIGHT_KG": "80" }
    }
  }
}
```

`treadmill_stop` returns the session summary (duration, distance, steps, avg speed, kcal) and writes it to `~/.z1-walkingpad/` (`sessions.jsonl` + per-session JSON; override with `Z1_SESSIONS_DIR`, e.g. an iCloud Drive folder — see `docs/apple-health.md`).

## How it works (the protocol)

The Z1 speaks standard Bluetooth SIG **FTMS** (`0x1826`) for control and telemetry — but **everything is gated behind a vendor unlock handshake** on the KingSmith supplement service (`24e2521c-…-c5330a00fdf7`). Until the unlock frame lands, the pad silently ignores every FTMS Control Point write and suppresses **all** notifications. This is why generic FTMS clients connect fine but can do nothing.

No bonding, no pairing, no MTU requirement: the name-derived unlock token is the entire auth mechanism.

### Connect sequence

1. Subscribe the supplement **notify** characteristic (`…b00fdf7`) **before writing anything**
2. Write the unlock frame to `…d00fdf7` **without response**:
   `71 00 05 01 <T> CC` where `T = LE32(last 4 chars of BLE name) + 1` and `CC = sum(all prior bytes) & 0xFF`.
   For `KS-HD-Z1D`: **`71 00 05 01 2e 5a 31 44 74`**
3. Pad replies `71 80` on the notify char (usually <100 ms) → unlocked
4. Optional session init: `SYS_INFO` (`71 01 08 <unix LE32> <uid LE32> CC` → `71 81`), `SETTING_GET` (`72 00 01 00 73` → `72 80` property dump)
5. FTMS now behaves like the textbook spec and telemetry notifications flow

### GATT map

| UUID | Props | Purpose |
|---|---|---|
| `00001826-…` | service | standard FTMS fitness machine service |
| `00002acc-…` | read | fitness machine features |
| `00002ad4-…` | read | supported speed range → **1.6–6.4 km/h** (0.1 steps) |
| `00002acd-…` | notify | treadmill data (live telemetry, ~1 frame/s while running) |
| `00002ada-…` | notify | machine status (04 started, 01/02 stopped) |
| `00002ad9-…` | write, indicate | **FTMS control point** (start/stop/speed) |
| `24e2521c-…-c5330a00fdf7` | service | KingSmith supplement service (the gate) |
| `24e2521c-…-c5330b00fdf7` | notify | supplement read channel |
| `24e2521c-…-c5330d00fdf7` | write, write-no-rsp | supplement write channel |
| `0xFFC0` / `0xFFF0` / `0xFF00` | — | JieLi-chip OTA — **do not touch** |

### Vendor (supplement) frames

```
[cmd0, cmd1, len, data[len], checksum]     checksum = sum(all prior bytes) & 0xFF
```

- Writes go to `…d00fdf7` as **write without response**, paced **≥400 ms** (faster writes are dropped)
- Unlock: `71 00 05 01 <T> CC` → `71 80`
- SYS_INFO: `71 01 08 <ts LE32> <uid LE32> CC` → `71 81`
- Property read all: `72 00 01 00 73` → `72 80`, data = 4-byte records `[id, error, valLo, valHi]`
- Property write: `72 01 03 <id> <lo> <hi> CC` → `72 81` (`data[1]=0` = OK)
- Unsolicited: property pushes `72 50`, exercise-record events `73 50`, fault records `73 51`
- **Never** send frames starting with `0xE8` (OTA mode — brick risk)

Properties observed on the Z1: `1` units/language (bit 1 = miles; written when the app syncs display units), `2` auto-stop, `4` motor version, `5` last error, `6` child lock, `8` switches (buzzer/light), `10` device mode — bits 5–7: 0=manual, 1=auto, 2=**sleep** (used by Exit).

### FTMS control (post-unlock)

Control point `0x2AD9`, write **with** response, pace ≥400 ms. Indication replies: `[0x80, request-op, result, …]`.

| Op | Bytes | Effect |
|---|---|---|
| Request Control | `00` | required once before any command |
| Reset | `01` | |
| Set Target Speed | `02 <u16 LE, km/h×100>` | e.g. 2.5 km/h = `02 fa 00` |
| Start/Resume | `07` | belt ramps to minimum speed (1.6 km/h); **fails (4) if belt already moving** |
| Stop / Pause | `08 01` / `08 02` | Stop finalizes the pad session (resets its counters) |

| Result | Meaning |
|---|---|
| 1 | success |
| 2 | op not supported |
| 3 | invalid parameter |
| 4 | failed |
| 5 | control not permitted → re-send `00`, retry once |

Typical session: `00` → `07` → `02 …` → `08 01`.

### Quick reference (build-your-own cheat sheet)

Connection constants:

- Scan name prefix `KS-HD-Z1`; vendor writes ≥**400 ms** apart (dropped if faster); write-without-response on the vendor char, with-response on the control point
- Await unlock `71 80` up to ~10 s (usually <100 ms); other vendor replies ~3 s; control indications ~3 s

Vendor channel (`…d00fdf7` write / `…b00fdf7` notify, frame `[cmd0, cmd1, len, data, sum&0xFF]`):

| Frame | Bytes | Reply |
|---|---|---|
| Unlock | `71 00 05 01 <LE32(name[-4:])+1> CC` | `71 80` |
| SYS_INFO | `71 01 08 <unix LE32> <uid LE32> CC` | `71 81` (proto u16, model u16, caps u32) |
| Property read (all / one) | `72 00 01 <id|00> CC` | `72 80` — 4-byte records `[id, err, lo, hi]` |
| Property write | `72 01 03 <id> <lo> <hi> CC` | `72 81` — `data[1]=0` OK |
| Func/method info | `75 00 00 75` | `75 80` |
| *(unsolicited)* | — | `72 50` property push (3-byte records), `73 50` exercise record, `73 51` fault |

Vendor control tunnel (alternative to FTMS control point; used as fallback by some clients): `77 01 <len> <op> <params…> CC` → reply `77 81`, `data[0]=op`, status `data[1]` (0 or 0x81 = OK). Ops mirror FTMS: start `77 01 01 07 7F`, stop `77 01 02 08 01 82`, speed `77 01 03 02 <u16 LE km/h×100> CC`.

Machine status (`0x2AD9` sibling `0x2ADA`, notify): `04` started, `02` user stop/pause, `01` safety-key stop, `05` speed changed, `FF` control lost.

Telemetry flags (`0x2ACD`, u16 LE then fields in order): bit0 *clear* → speed u16 (km/h×100) · bit1 avg speed u16 · bit2 distance u24 m · bit3 incline+ramp s16×2 · bit4 ±elevation u16×2 · bit5 pace u8 · bit6 avg pace u8 · bit7 energy u16+u16+u8 · bit8 HR u8 · bit9 MET u8 · bit10 elapsed u16 s · bit11 remaining u16 s · **bit13 steps u16 (KingSmith)**. Z1 sends flags `0x2404` + speed.

Device facts: firmware `V0.0.6` (`0x2A26`), speed range 1.6–6.4 km/h (`0x2AD4`, u16×2 km/h×100), one BLE connection at a time, no GAP service.

### Telemetry

FTMS treadmill data `0x2ACD`: flags u16 LE, fields in flag order. The Z1 sends distance (bit 2, u24 m), elapsed time (bit 10, u16 s), **step count (bit 13, u16 — KingSmith extension)**, plus instantaneous speed (bit 0 clear, u16 km/h×100). Counters are cumulative and persist across BLE connections while the session is open.

### What the pad does NOT provide

- **Calories / heart rate** — no HR sensor, no energy bit in telemetry. Calories are computed locally (below).
- **Display/screen control** — not exposed over BLE at all; the LED panel cycling is RF-remote only.
- **Incline** — fixed hardware.

### Calories (computed locally)

The **ACSM walking metabolic equation** (exercise-physiology standard, level grade):

```
VO2 (ml/kg/min) = 0.1 × speed(m/min) + 3.5
kcal/min        = VO2 × weight_kg / 200
```

Continuous in speed; chosen over the Compendium MET table because research shows fixed MET buckets misclassify intensity at slow walking speeds (PubMed 35876127). Expect ±10–15% real-world error. Weight: `Z1_WEIGHT_KG` (Python) or the in-app setting (macOS).

## How this was found

Static reverse engineering under constraints (no official-app install, no extra hardware): blutter disassembly of the KS Fit Android app, upstream issue archaeology, and the breakthrough — the [duttke.de Web Bluetooth implementation](https://www.duttke.de/en/walkingpad/), whose unlock variant is the one firmware V0.0.6 accepts. Full story: **`docs/reverse-engineering.md`**. Byte-level spec: **`docs/protocol.md`**.

## Repository layout

```
src/z1_walkingpad_mcp/
  ├── protocol.py/constants.py   Core: frame builders/parsers, UUIDs, opcodes
  ├── client.py                  Core: Z1Treadmill async BLE client
  ├── metrics.py                 Core: ACSM calorie estimation
  ├── cli.py                     Frontend: command line
  ├── server.py                  Frontend: MCP server
  └── strava.py                  Frontend: optional Strava upload (unused by default)
macos/                         Frontend: native menu-bar app (Swift, independent build)
docs/                          protocol.md · reverse-engineering.md · apple-health.md · strava.md
scripts/                       The BLE reverse-engineering record (incl. the winning replay)
tests/                         Python unit tests (no BLE needed)
```

## Safety model

| Operation | Mutating? | Notes |
|---|---|---|
| Scan / connect / read / notify | No | Unlock is a no-op auth handshake, not a command |
| Request Control (`0x00` write) | Yes (control claim) | Required before commands; does not move belt |
| Start / Stop / Set Speed / Sleep | Yes | Only ever sent deliberately (Exit sends stop + sleep) |

The pad allows one BLE connection at a time; close other controllers before connecting.
