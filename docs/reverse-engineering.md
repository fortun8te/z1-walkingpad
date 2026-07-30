# How the Z1 was cracked — a reverse-engineering log

The short version: the WalkingPad Z1 is a perfectly standard FTMS treadmill
hiding behind a 9-byte vendor unlock frame. Everything — every ignored
command, every silent notification — was that one gate. This is the log of
how we found it, in order, including the dead ends (they're most of the
story).

## The symptom

Connect to the pad (`KS-HD-Z1D`) with any BLE client and everything *looks*
fine: GATT enumerates, reads work, writes get acked. But:

- FTMS Control Point (`0x2AD9`) commands are silently ignored. `0x07`
  (start) and `0x08` (stop) produce an audible beep — the pad *processes*
  the write — and nothing else. No indication response, no motion.
- **Zero notifications. Ever.** Raw CoreBluetooth with every CCCD enabled
  heard nothing on any characteristic, in any state.

That combination — acks but no indications, no notifications — ruled out
"dumb client" bugs and pointed at an application-level gate.

## Dead end 1: standard FTMS tooling

[`walkingpad-controller`](https://github.com/mcdax/walkingpad-controller)
(confirmed working on this exact model, KS-Z1D) failed identically:
"Control point response timeout for opcode 0x00/0x07/0x08", "START_OR_RESUME
rejected and belt is not moving". Upstream issue
[#3](https://github.com/mcdax/walkingpad-controller/issues/3) is this exact
device and firmware: on Linux, telemetry works but control doesn't; on
macOS, nothing at all. So it wasn't us.

## Dead end 2: reverse-engineering KS Fit (blutter)

Constraint: the official app was not to be installed anywhere, so no live
traffic capture. Instead, static analysis: downloaded KS Fit APKs
(`apkeep`), and since the app is Flutter/Dart AOT, used
[blutter](https://github.com/worawit/blutter) to disassemble
`libapp.so` (arm64) from v5.9.10 and v6.0.7.

That yielded a real protocol: a supplement service
(`24e2521c-…-c5330a00fdf7`, write `…d00fdf7`, notify `…b00fdf7`) with
frames `[body…, sum(body)&0xFF]` and an unlock command
`E2 00 0A RR <BE32(name[-4:])+RR as LE> CC`, answered by `71 80`.
It also yielded vendor FTMS opcodes (`00` wake → `0E` start → `04 LL HH`
speed → `10 02` stop) used by the app on some devices.

Every replay failed: propertyList/unlock/vendor-opcode swings, fuzzed
frame variants, CCCD audits, connect-during-boot pairing-window timing,
full power cycles. Acked, beeped (sometimes), never answered, never moved.

## Dead end 3: the pairing hypothesis

Leading theory for a while: the pad requires a bonded/encrypted link, which
macOS never initiates (no encryption-protected characteristics) but BlueZ
might — neatly explaining the Linux/macOS split in issue #3. The blutter
dig killed it: KS Fit contains zero `createBond` usage outside dead library
code, and its own troubleshooting strings tell users to *unpair* the device.
The unlock token is the auth; LE pairing is explicitly unwanted.

## The break: duttke.de

The overlooked lead was [duttke.de/en/walkingpad](https://www.duttke.de/en/walkingpad/) —
a Web Bluetooth page that controls these treadmills from a browser. No
install needed, so it fit the constraints, and its JavaScript is readable.
Its bundle contains a complete, *working* implementation — and its unlock
is **different** from the KS Fit one:

- frame `71 00 05 01 <LE32(name[-4:])+1> CC` (not `E2 00 0A RR …`;
  different opcode, different endianness, fixed +1 instead of a random byte)
- written **without response** (we had used with-response; some firmware
  silently drops the other kind)
- notify subscription **before** the write, ≥400 ms pacing between vendor
  frames, replies parsed as `71 80` (unlock ok) / `72 80` (properties)

First replay (`scripts/duttke_replay.py`): `71 80` came back in 58 ms —
the first notification the pad had ever sent us — then SYS_INFO, a property
dump, and a clean FTMS session: request control, start, set speed 2.5 km/h,
15 seconds of telemetry, stop. The belt moved.

With the gate open, everything else was standard FTMS by the book.

## Why our KS Fit frames never worked

Still slightly mysterious, honestly. The blutter-derived `E2` frame was
byte-correct per the app's own construction, and the app obviously works
with the pad. Best explanation: firmware V0.0.6 on the Z1D expects the
`0x71`-family request (the duttke form) — the `E2` path may be for other
firmware revisions or require a preceding exchange we never replicated.
Both forms receive the same `71 80` reply from pads that accept them.
The v5.9.10↔v6.0.7 diff showed the wire protocol unchanged between app
versions, so this is a device/firmware-side variant, not an app-version one.

## What the Bluetooth stack actually is

- **Standard FTMS** (`0x1826`) for the useful stuff: control point
  (`0x2AD9`), treadmill data (`0x2ACD`), speed range (`0x2AD4`), machine
  status (`0x2ADA`). Textbook except for KingSmith's step-count extension
  (flags bit 13).
- **KingSmith supplement service** (`24e2521c-…`) — a tiny framed RPC
  channel (`[cmd0, cmd1, len, data, sum]`): unlock, system info, property
  get/set (child lock, mode, auto-stop, buzzer…), exercise/fault events.
  It is the gatekeeper and the settings interface, nothing more.
- **JieLi-chip OTA services** (`0xFFC0`/`0xFFF0`/`0xFF00`) — firmware
  update channel. Identified, deliberately untouched.
- **Not on BLE at all:** the remote (Sub-GHz RF) and the LED display
  cycling. The firmware exposes no display-control characteristic; even the
  duttke implementation throws "FTMS does not expose panel-display
  configuration" for this device family.

## Constraints that shaped the hunt

No KS Fit install (so no PacketLogger/HCI ground truth, everything static),
no extra hardware (no ESP32 sniffer), BLE only (no Flipper RF relay), and a
strong preference for "working today". The winning path cost: two APK
downloads, one blutter run, one curl of a JavaScript bundle, and one
9-byte frame.

The full wire spec is in `docs/protocol.md`. The replay that first moved
the belt is preserved at `scripts/duttke_replay.py`, alongside the failed
experiments (`unlock_swings.py`, `fuzz_unlock.py`, `instant_connect.py`, …)
for anyone who wants the full battlefield.
