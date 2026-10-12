# Z1 WalkingPad

A small native Mac app for the KingSmith WalkingPad Z1 (`KS-HD-Z1D`). It
connects over Bluetooth, starts, stops and sets the speed of the belt, keeps a
history of finished walks, and hands them on: a `live.json` for other local
apps and a queue file the iPhone Shortcut turns into Apple Health workouts.

The pad speaks Bluetooth FTMS (`0x1826`) behind a vendor unlock. The handshake
is documented in [docs/protocol.md](docs/protocol.md). Physical control lives
only in the native app; the Python side in `src/` is a read-only stats server.

## The app

One fixed 320 × 414 window with a Dock icon and a normal menu bar. Closing the
window keeps the app running (the walk keeps being recorded and ⌃⌥W keeps
working); the Dock icon or ⌘0 brings it back. Three pages swap inside it
(⌘1 to ⌘3) and nothing resizes or animates.

- **Now**: the pad's state beside the traffic lights, a dot-matrix speed
  readout, the speed ruler with − / +, Start/Stop, this walk's time and
  distance while the belt moves, and today's minutes against the goal.
- **History**: one week of goal bars. ‹ › page by week; click a bar for that
  day's time and distance.
- **Settings**: daily goal in minutes, units (metric or imperial), quiet-day
  reminders, start at login. The build, for example `Z1 2.0 (build
  202610131200)`, sits quietly at the bottom and in the About panel.

Picking a speed: press or drag anywhere on the ruler, nudge with − / + or ← →
(0.1) and ↑ ↓ (0.5), or click the readout and type (3 then 5 is 3.5, Return
sets it, Esc cancels). The pad only takes speed changes while the belt moves,
so a speed picked at a standstill is queued ("Starts at 3.0 km/h") and applied
the moment you press Start. Space starts and stops with the window in front;
⌃⌥W does it from anywhere, and connects when there is no pad yet.

Quitting while the belt moves asks first: **Stop Belt and Quit** stops it and
puts the pad to sleep, **Quit, Keep Walking** leaves it running. Walk ▸ Stop Pad
and Quit does the first without the question.

The look is settled and described in [docs/ui-systems.md](docs/ui-systems.md).

### Staying connected

The app remembers the pad's peripheral identifier and re-adopts it directly
instead of scanning, retries with a backoff after a drop, reconnects when the
Mac wakes, and holds an idle-sleep assertion for exactly as long as the belt
moves so a long walk is not cut in half. It cannot defeat closing the lid.

The pad accepts one Bluetooth controller at a time: quit KS Fit (and the
Python tools in `scripts/`) before connecting, and never pair the pad in macOS
Bluetooth settings. The first launch asks for Bluetooth permission; if you
deny it, enable "Z1 WalkingPad" in System Settings ▸ Privacy & Security.

### What it writes

All of it under `~/Library/Application Support/Z1 WalkingPad/` except the Health
queue.

| File | What |
| --- | --- |
| `sessions.json` | Every finished walk of two active minutes or more. A walk is one belt run; it ends two minutes after Stop. |
| `live.json` | Read-only snapshot for Superapp and the MCP: [docs/live-json.md](docs/live-json.md). |
| `health-queue.json` | In the Shortcuts iCloud folder: workouts of at least 10 minutes and 100 m for the iPhone Shortcut. [docs/apple-health.md](docs/apple-health.md). |
| `health-queue-receipts.json`, `health-queue-cutover.json` | What the Mac already queued, and the first-run cutover. Receipts record queueing, not import. |

Belt distance is the one exact figure. Steps and kilocalories are estimates;
the window does not show them, `live.json` and the history carry them.

An idle app does no work: no polling, no animation. What it schedules is
one-shot and event-driven: the reconnect backoff while there is no pad, the
deadlines that close a walk (two minutes after Stop, ten for the Health
workout), and one reminder check armed for the next moment a reminder could be
due.

## Build and test

Swift 6, no third-party dependencies, deployment target macOS 14. With the
macOS 26 SDK the controls are Liquid Glass; older toolchains build flat ones.

```bash
cd macos
bash build-app.sh              # release bundle in dist/Z1WalkingPad.app, installs nothing
bash build-app.sh --debug      # faster debug bundle
swift run z1tests              # the Swift assertions, with fake transports
```

`build-app.sh` writes version 2.0 and a build number that is the minute of the
build (`yyyyMMddHHmm`), and signs ad hoc with the Bluetooth entitlement. To use
a build, quit the running app and `ditto dist/Z1WalkingPad.app
/Applications/Z1WalkingPad.app`. The bundle id stays `dev.z1walkingpad.menubar`
so settings, the remembered pad and the Bluetooth permission carry over.

`swift test` compiles and links the suite but runs none of its assertions
(this project does not use XCTest); `swift run z1tests` does. For Python:

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev]"
.venv/bin/python -m pytest -q
```

### Looking at the window without a pad

The preview harness opens the window with no Bluetooth and a scratch history:

```bash
cd macos
swift build --scratch-path .build-frontend --product Z1App
Z1_PREVIEW=1 Z1_PREVIEW_DEMO=1 Z1_PREVIEW_SPEED=3.4 \
  .build-frontend/debug/Z1App -z1.hasSeenIntro 1
# prints Z1_PREVIEW_WINDOW <n>; then: screencapture -o -l <n> now.png
```

`Sources/Z1App/PreviewHarness.swift` lists every switch (page, appearance,
phase, queued speed, a failed command, typing, the About panel).

### Hardware

`swift run z1smoke` scans, connects, unlocks and waits for one telemetry frame.
It sends no control writes, so the belt never moves. Never send frames that
start with `0xE8` (OTA, can brick the pad) or touch the `0xFFC0`, `0xFFF0` and
`0xFF00` services. Automated tests, the preview harness and a green build say
nothing about a real reconnect, a real Stop or the iPhone Health import; those
need the pad and the phone.

## Read-only MCP

`src/z1_walkingpad_mcp` serves one tool, `z1(q=today|live|all|list)`, from the
files above. It cannot control the pad.

```bash
.venv/bin/python -m z1_walkingpad_mcp.server
```

## Layout

| Path | What |
| --- | --- |
| `macos/Sources/Z1Core` | CoreBluetooth transport, the `Z1Treadmill` actor, frames, session store, Health queue, `live.json` writer. No AppKit. |
| `macos/Sources/Z1App` | The window: AppKit shell, SwiftUI content. |
| `macos/Sources/Z1Smoke` | `z1smoke`, the hardware smoke test. |
| `macos/Sources/Z1CoreTestSuite`, `z1tests`, `macos/Tests` | The test suite, its runner and the `swift test` anchor. |
| `macos/build-app.sh`, `macos/Resources` | The bundle script, the app icon (`AppIcon.icns`) and its editable source (`AppIcon.svg`). |
| `src/`, `tests/` | The read-only MCP and its tests. |
| `shortcuts/` | Source of the iPhone Shortcut, built by `scripts/build_health_shortcut.sh`. |
| `scripts/` | Protocol experiments from the reverse engineering, kept as a record. They talk to a real pad. |
| `docs/` | Protocol, discovery notes and the app's data and design documents. |

## License

MIT. See [LICENSE](LICENSE).
