#!/usr/bin/env python3
"""Comprehensive one-shot protocol test for the Z1.

Phases:
  1. Poll KingSmith ask_stats on 0xFFF2 (then 0xFFC2) — telemetry probe, belt idle
  2. Vendor start sequence: manual mode, start belt, set 1.6 km/h, poll, stop
  3. FTMS fallback: start, set 1.6 km/h, stop
Always stops the belt in a finally block. Total runtime ~75s.

WARNING: this script MOVES THE BELT (min speed, ~12s). Run only with nobody on the pad.
"""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

FFF2 = "0000fff2-0000-1000-8000-00805f9b34fb"
FFC2 = "0000ffc2-0000-1000-8000-00805f9b34fb"
SPEED_UNITS_MIN = 16  # 1.6 km/h in vendor units (speed * 10)


def crc(cmd: list[int]) -> bytearray:
    cmd[-2] = sum(cmd[1:-2]) % 256
    return bytearray(cmd)


ASK_STATS = crc([247, 162, 0, 0, 0, 253])
MODE_MANUAL = crc([247, 162, 2, 1, 0, 253])
BELT_START = crc([247, 162, 4, 1, 0, 253])
SET_SPEED_MIN = crc([247, 162, 1, SPEED_UNITS_MIN, 0, 253])
SET_SPEED_ZERO = crc([247, 162, 1, 0, 0, 253])


def parse_status(data: bytearray) -> str:
    if len(data) >= 18 and data[0] == 248 and data[1] == 162:
        def b2i(o): return data[o] * 65536 + data[o + 1] * 256 + data[o + 2]
        return (f"STATUS state={data[2]} speed={data[3]/10}km/h mode={'manual' if data[4] else 'auto'} "
                f"time={b2i(5)}s dist={b2i(8)/100}km steps={b2i(11)} app_speed={data[14]/10}")
    return ""


async def main() -> None:
    print("scanning...", flush=True)
    device = None
    for d in await BleakScanner.discover(timeout=15):
        if d.name and d.name.startswith(c.DEVICE_NAME_PREFIX):
            device = d
            break
    if device is None:
        print("Z1 not found")
        sys.exit(1)
    print(f"found {device.name}", flush=True)

    traffic = []

    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                parsed = parse_status(data)
                line = f"[{label}] {data.hex()} {parsed}"
                traffic.append(line)
                print(line, flush=True)
            return handler

        for service in client.services:
            for char in service.characteristics:
                if "notify" in char.properties or "indicate" in char.properties:
                    try:
                        await client.start_notify(char.uuid, make_handler(char.uuid[:13]))
                    except Exception:
                        pass

        working_write_char = None

        # Phase 1: telemetry probe on vendor channels (belt untouched)
        for label, char in [("fff2", FFF2), ("ffc2", FFC2)]:
            print(f"\n=== PHASE 1: poll ask_stats on {label} for 8s ===", flush=True)
            before = len(traffic)
            for _ in range(10):
                try:
                    await client.write_gatt_char(char, ASK_STATS, response=False)
                except Exception as e:
                    print(f"write to {label} failed: {e}", flush=True)
                    break
                await asyncio.sleep(0.75)
            if len(traffic) > before:
                working_write_char = char
                print(f">>> {label} RESPONDS — vendor protocol lives here", flush=True)
                break
            print(f"no response on {label}", flush=True)

        # Phase 2: vendor belt control
        if working_write_char:
            print("\n=== PHASE 2: vendor belt control (manual, start, 1.6km/h, 12s, stop) ===", flush=True)
            try:
                await client.write_gatt_char(working_write_char, MODE_MANUAL, response=False)
                await asyncio.sleep(1)
                await client.write_gatt_char(working_write_char, BELT_START, response=False)
                await asyncio.sleep(2)
                await client.write_gatt_char(working_write_char, SET_SPEED_MIN, response=False)
                for _ in range(16):
                    await client.write_gatt_char(working_write_char, ASK_STATS, response=False)
                    await asyncio.sleep(0.75)
                print(">>> if the belt moved, vendor control WORKS", flush=True)
            finally:
                await client.write_gatt_char(working_write_char, SET_SPEED_ZERO, response=False)
                await asyncio.sleep(1)
                await client.write_gatt_char(working_write_char, SET_SPEED_ZERO, response=False)

        # Phase 3: FTMS control
        print("\n=== PHASE 3: FTMS control (request, start, 1.6km/h, 10s, stop) ===", flush=True)
        try:
            await client.write_gatt_char(c.CHAR_CONTROL_POINT, bytes([0x00]), response=True)
            await asyncio.sleep(0.5)
            await client.write_gatt_char(c.CHAR_CONTROL_POINT, bytes([0x02, 0xA0, 0x00]), response=True)  # 1.60 km/h
            await asyncio.sleep(0.5)
            await client.write_gatt_char(c.CHAR_CONTROL_POINT, bytes([0x07]), response=True)  # start
            print("FTMS start sent — belt should be moving at 1.6 km/h for 10s", flush=True)
            await asyncio.sleep(10)
        except Exception as e:
            print(f"FTMS control error: {e}", flush=True)
        finally:
            try:
                await client.write_gatt_char(c.CHAR_CONTROL_POINT, bytes([0x08, 0x01]), response=True)  # stop
                print("FTMS stop sent", flush=True)
            except Exception as e:
                print(f"FTMS stop error: {e}", flush=True)

        print("\nlistening 5s for late traffic...", flush=True)
        await asyncio.sleep(5)
        print(f"\nDONE. {len(traffic)} notification(s) captured total.", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
