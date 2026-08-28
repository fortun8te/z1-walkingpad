# macOS — Z1 WalkingPad menu-bar app

Native macOS control for the KingSmith WalkingPad Z1 treadmill over BLE.
Swift 6, no third-party dependencies. The wire protocol is specified in
[`../docs/protocol.md`](../docs/protocol.md) — read it before changing any
frame code. **Never** send frames starting with `0xE8` (OTA, brick risk) and
never touch the `0xFFC0`/`0xFFF0`/`0xFF00` services.

## Layout

| Piece | What |
|---|---|
| `Sources/Z1Core` | Pure CoreBluetooth + Foundation library: vendor/FTMS frames, BLE transport, `Z1Treadmill` actor, calorie metrics. No AppKit/SwiftUI. |
| `Sources/Z1MenuBar` | SwiftUI `MenuBarExtra` app (deployment target macOS 14, activation policy `.accessory` — no Dock icon). |
| `Sources/Z1Smoke` | `z1smoke` — hardware smoke test (connect, unlock, read telemetry; **never moves the belt**). |
| `Sources/Z1CoreTestSuite` + `Sources/z1tests` | Framework-free unit tests + runner executable (see "Testing"). |
| `Tests/Z1CoreTests` | `swift test` anchor (compiles/links the suite). |
| `build-app.sh` | Release build → `Z1WalkingPad.app` → codesign with a stable identity (`Michael Computer Use Signing`, ad-hoc fallback) and Bluetooth entitlements, then **ditto in place** into `/Applications` (keeps Bluetooth TCC). Use `--no-install` to keep the bundle in `macos/`. |

## Build & run

Requires a Swift 6 toolchain (Command Line Tools is enough — no full Xcode
needed). Developed with Swift 6.2.3, target `arm64-apple-macosx15.0`.

```bash
cd macos

swift build                     # debug build of everything
swift test                      # compiles the test suite (see "Testing")
swift run z1tests               # actually runs the unit tests
bash build-app.sh               # release build, stable codesign, in-place install
                                #   (staging copy in macos/ is removed)
bash build-app.sh --no-install  # leave the bundle in macos/ instead
```

Then open the app:

```bash
open -a Z1WalkingPad           # installed bundle; with --no-install: open macos/Z1WalkingPad.app
```

A `figure.walk` icon appears in the menu bar, with a configurable readout
beside it. Click it for the popover: connect/disconnect, big speed readout with
− / + steppers, an exact-speed field and slider, Start/Stop, stats (elapsed,
distance, steps, estimated kcal), an almanac card whose tile strip toggles
between This week and 30 days on click, resetting the detail to Today each time
(each day a small sky tile lit by goal progress), walk history, and a
Settings section:

Steps can be pinned to a **hand-measured stride** (Settings → Your stride).
This matters more than it looks: the pad's step sensor has never been validated,
and the stride learner derives its curve *from* that sensor — so if the pad
over-counts, the learner converges on a correspondingly short stride and every
number stays self-consistent and wrong. Belt distance is the one exact figure,
so counting your own steps once and entering metres-per-step makes the rest
follow from it. Leave it at 0 to trust the pad. The popover shows the stride
your current numbers imply, in m/step and steps/km, to compare against a count.

Left on auto, the step count is a **self-calibrating estimate**, not a blind
copy of the pad's number. The app preserves every trusted-speed raw step, learns only from
stable 12-second windows, requires three windows and 100 m, and rejects
impossible stride samples. It then derives slow-speed steps from belt distance
without jumping totals when calibration activates.

- **Units** — Metric (km/h / km / kg) by default, with optional Imperial
  (mph / mi+ft / lb). Also synced to the pad's own LED display (property 1, bit 0x0002).
- **Body weight** — entered in the current unit, stored in kg for the
  calorie math.
- **Speed step** — stepper nudge size: 0.1 / 0.2 / 0.5 in the display unit
  (converted to km/h on the wire, rounded to the pad's 0.1 km/h steps).
- **Persist stats across sessions** — off (default) means pad-as-master:
  stats follow the pad's counters and its resets. On means time, distance,
  steps and kcal keep accumulating across Stops until you hit the **Clear**
  button beside it (which also wipes the on-disk calorie state).

- **Menu bar shows** — icon only, or speed / elapsed / distance / steps /
  calories / today's minutes / today's steps beside it, with **Show even when
  stopped** to keep it visible at a standstill.
- **Daily goal** — minutes per day (default 120) **or** steps per day
  (default 8,000), selectable in Settings; drives the progress bar under
  "Today" and the sky tiles in the almanac card.
- **Start at login** — registers the app with `SMAppService`. Only works from
  an installed bundle (`build-app.sh` without `--no-install`), and the reason
  is shown inline when it does not take.
- **Notify when a walk is recorded** — a local notification per finished walk.

All settings persist across launches. Two exits sit at the bottom of the
popover: **Quit** leaves the belt exactly as it is (for when you are still
walking and just want the pad's single BLE slot back), and **Stop belt & quit**
stops the belt, sleeps the pad, then quits.

### Picking a speed

The − / + steppers nudge by the configured step. To go straight to a value,
type it in the **Set** field (Enter applies it) or drag the slider — both in
0.1 increments across the pad's 1.6–6.4 km/h range. The pad only accepts speed
changes while the belt is moving, so a speed picked at a standstill is
remembered and applied the moment you press Start.

### Today and history

Every finished walk of two minutes or more is written to
`~/Library/Application Support/Z1 WalkingPad/sessions.json`. Walks under
2 active minutes are treated as noise (stepping on the belt for a moment) and
are never recorded — this is the app's own history rule, separate from the
10-minute/100 m minimum Apple Health uses when exporting workouts. The popover
shows today's totals against your goal, an almanac strip of day tiles lit by
goal progress that toggles between This week and 30 days on click (Today is
always the default detail day), and the last five walks, each marked with
whether it was recorded.

### Staying connected

The app is built to be running whenever you are. It remembers the pad's
peripheral identifier and re-adopts it directly instead of scanning, retries
with a backoff after a drop, reconnects immediately when the Mac wakes, and
holds an idle-sleep assertion for exactly as long as the belt is moving so a
long walk cannot be cut in half by the Mac dozing off. It cannot defeat closing
the lid or an explicit Sleep.

### Local session history

Finished walks live only on this Mac:
`~/Library/Application Support/Z1 WalkingPad/sessions.json`. There is no
default iCloud Drive, Shortcuts, Apple Health, or WHOOP queue. Use the
physical remote as usual while the menu-bar app is connected; the popover
shows today's totals and recent walks from that local file.

## Bluetooth permission

On first launch macOS asks for Bluetooth permission
(`NSBluetoothAlwaysUsageDescription` is in the bundled Info.plist). Signed
with the same identity (`Michael Computer Use Signing`) and **installed in
place** (the build script ditto's into `/Applications/Z1WalkingPad.app`
without deleting the bundle first), that prompt happens **once**. Rebuilds
keep the TCC grant. Ad-hoc signing or deleting the app from `/Applications`
will make macOS ask again.

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
