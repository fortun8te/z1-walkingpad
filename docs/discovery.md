# Discovery log — WalkingPad Z1

Captured 2026-07-29 via `scripts/discovery.py` (read-only, zero writes sent).

## Identity

| Field | Value |
|---|---|
| Advertised name | `KS-HD-Z1D` |
| macOS BLE address | `1DC6DC0D-BADF-6C1B-453D-A2DD53A298D2` (CoreBluetooth UUID, per-Mac) |
| Manufacturer string | `1D` |
| Model string | `KS-Z1D` |
| Firmware | `J41_V301.08.14` |
| Hardware | `MKS` |
| Supported speed | 1.60 – 6.40 km/h, step 0.10 |

## GATT layout

- `0x180A` Device Information (standard strings)
- `0x1826` Fitness Machine (FTMS)
  - `0x2ACC` Fitness Machine Feature (read)
  - `0x2ADA` Fitness Machine Status (read, notify)
  - `0x2ACD` Treadmill Data (notify)
  - `0x2AD3` Training Status (read, notify)
  - `0x2AD4` Supported Speed Range (read)
  - `0x2AD5` Supported Inclination Range (read)
  - `0x2AD7` Supported Heart Rate Range (read)
  - `0x2AD9` Fitness Machine Control Point (write, indicate) ← all commands go here
- `0xFFC0`, `0xFFF0`, `0xFF00` vendor services (notify + write chars) — unexplored
- `24e2521c-…` unknown vendor service — unexplored

## Open questions

- Treadmill Data sent no notifications during a 15s listen while the belt was idle.
  Hypotheses: (a) only notifies while belt is running, (b) requires FTMS Request
  Control (`0x00` write to `0x2AD9`) first, (c) notification parsing/enabling needs
  a vendor command. Test while belt is moving.
- Whether control works exactly per FTMS spec (op `0x02` set speed in 0.01 km/h)
  or needs the vendor `0xFFF0` channel like older KingSmith models.
