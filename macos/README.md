# macOS — Z1 WalkingPad app

Native macOS control for FTMS walking pads over BLE (KingSmith WalkingPad Z1
and other 0x1826 treadmills). KingSmith still gets the vendor unlock. Everyone
else uses the standard start/stop/speed control point.
Swift 6, no third-party dependencies. The wire protocol is specified in
[`../docs/protocol.md`](../docs/protocol.md) — read it before changing any
frame code. **Never** send frames starting with `0xE8` (OTA, brick risk) and
never touch the `0xFFC0`/`0xFFF0`/`0xFF00` services.

## Layout

| Piece | What |
|---|---|
| `Sources/Z1Core` | Pure CoreBluetooth + Foundation library: vendor/FTMS frames, BLE transport, `Z1Treadmill` actor, calorie metrics, session store. No AppKit/SwiftUI. |
| `Sources/Z1App` | The app: one small fixed window (AppKit shell, SwiftUI content, deployment target macOS 14), Dock icon, normal menu bar. |
| `Sources/Z1Smoke` | `z1smoke` — hardware smoke test (connect, unlock, read telemetry; **never moves the belt**). |
| `Sources/Z1CoreTestSuite` + `Sources/z1tests` | Framework-free unit tests + runner executable (see "Testing"). |
| `Tests/Z1CoreTests` | `swift test` anchor (compiles/links the suite). |
| `build-app.sh` | Release build → `dist/Z1WalkingPad.app`, ad-hoc signed with the Bluetooth entitlement. It installs nothing and touches no running copy. |

## Build & run

Requires a Swift 6 toolchain (Command Line Tools is enough — no full Xcode
needed).

```bash
cd macos

swift build --scratch-path .build-frontend --product Z1App   # debug build of the app
swift run z1tests                                             # runs the unit tests
bash build-app.sh                                             # release bundle in dist/
bash build-app.sh --debug                                     # faster debug bundle
```

To use a build, quit the running copy, then copy `dist/Z1WalkingPad.app` to
`/Applications` yourself (`ditto dist/Z1WalkingPad.app /Applications/Z1WalkingPad.app`
replaces it in place). The bundle id stays `dev.z1walkingpad.menubar`, so
settings, the remembered pad and the Bluetooth permission carry over.

### The window

One small fixed window (320 × 476). Pages swap inside it — **Now**, **History**,
**Records**, **Settings** (⌘1–⌘4, also in the View menu) — and nothing ever
resizes or animates. The background is flat and follows the system's light or
dark appearance (dark is near-black). Blue is the only colour: it means the belt
is moving, or progress toward today's goal.

- **Now** — only what matters while walking: the pad's state beside the
  traffic lights, a dot-matrix speed readout (click it to type an exact
  speed), the speed ruler with − / + and five presets, Start/Stop (Space here,
  ⌃⌥W anywhere), this walk's numbers while the belt moves, and Today against
  the goal. Estimates say "est.".
- **History** — the almanac (Day / Week / Month with ‹ ›, the focused day's
  distance, time, steps, kcal), then recent walks by day.
- **Records** — best walks, best days, badges.
- **Settings** — daily goal (minutes or steps), speed step, units, body weight
  (optionally from Apple Health), notifications and quiet-day reminders, stride,
  ⌃⌥W, start at login, connect/disconnect, and the two quits.

Closing the window keeps the app running (the walk keeps being recorded and
⌃⌥W keeps working); the Dock icon or ⌘0 brings it back. Quitting while the
belt moves asks first: **Stop Belt and Quit** stops the belt and sleeps the
pad, **Quit, Keep Walking** leaves the belt as it is.

UI harness, no Bluetooth and a scratch history:
`Z1_PREVIEW=1 Z1_PREVIEW_DEMO=1 .build-frontend/debug/Z1App -z1.hasSeenIntro 1`
prints the window number for `screencapture -l`. See
`Sources/Z1App/PreviewHarness.swift` for the other switches (speed, queued
speed, page, lens, appearance, ticking telemetry).

### Picking a speed

Press anywhere on the ruler to jump there, drag to fine-tune, tap a preset
(2.5–4.5 km/h), or use the keys: ← → move by the configured step (0.1 by
default), ↑ ↓ by 0.5. Click the readout to type an exact value. The pad only
accepts speed changes while the belt is moving, so a speed picked at a
standstill is queued ("Starts at 3.0 km/h") and applied the moment you press
Start.

### Steps

Belt distance is the one exact figure; steps and kcal are estimates and are
labelled "est." everywhere. Settings shows the stride the current numbers imply.

### Today and history

Every finished walk of two minutes or more is written to
`~/Library/Application Support/Z1 WalkingPad/sessions.json`. Walks under
2 active minutes are treated as noise and never recorded. Today's numbers fold
in the walk still in progress.

### Staying connected

The app is built to be running whenever you are. It remembers the pad's
peripheral identifier and re-adopts it directly instead of scanning, retries
with a backoff after a drop, reconnects immediately when the Mac wakes, and
holds an idle-sleep assertion for exactly as long as the belt is moving so a
long walk cannot be cut in half by the Mac dozing off. It cannot defeat closing
the lid or an explicit Sleep.

## Bluetooth permission

On first launch macOS asks for Bluetooth permission
(`NSBluetoothAlwaysUsageDescription` is in the bundled Info.plist). Builds are
ad-hoc signed, so a replaced bundle may ask again; copying it over the old one
in place (`ditto`) rather than deleting first keeps that to a minimum.

If you accidentally deny it: System Settings → Privacy & Security → Bluetooth →
enable "Z1 WalkingPad".

For the command-line tools (`z1smoke`, `z1tests`) the permission prompt is
attributed to your terminal app (Terminal/iTerm) instead.

**One BLE connection at a time:** the Z1 accepts a single BLE central. If the
KS Fit app (or the Python MCP server/CLI in this repo) is connected, this app
won't find the pad — and vice versa. Quit the other client first. The pad is
also deliberately anti-pairing: do not pair it in macOS Bluetooth settings.

## Testing

This machine has **Command Line Tools only**, and neither XCTest nor
swift-testing ships with CLT — `swift test` can compile the test target but
Apple's runner frameworks are absent, so it executes zero tests. The unit
tests are therefore a framework-free suite:

- `swift test` — compiles and links the whole suite (exit 0).
- `swift run z1tests` — **runs** all assertions, exits non-zero on failure.

Covered: unlock-frame known vector (`KS-HD-Z1D` → `71 00 05 01 2e 5a 31 44 74`),
checksum roundtrip, bad-checksum/short-frame rejection, SETTING_GET vector,
property-record parsing, telemetry parse (`04 24 fa 00 00 00 00 02 00 00 00`
→ 2.5 km/h / 0 m / 2 s / 0 steps), u24 distance, MET table anchors +
interpolation + clamping, `kcal/min(3.2, 75) = 3.9375`, `CalorieTracker`.
The suite also covers remote Start/Stop detection, the fixed 10-minute merge
window, counter resets across a resumed segment, relaunch recovery, validation,
session merge windows, counter resets, and local session persistence.

## Hardware smoke test

```bash
swift run z1smoke          # add a number to change the telemetry wait (default 8s)
```

Scans for `KS-HD-Z1*`, connects, performs the unlock handshake, reads the
speed range + property dump, waits for one telemetry frame (the pad only
streams while the belt runs, so "no telemetry" with an idle belt is fine),
then disconnects. It sends **no FTMS control writes** — the belt never moves.
