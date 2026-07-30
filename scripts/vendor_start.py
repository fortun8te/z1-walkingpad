#!/usr/bin/env python3
"""Vendor opcode test: 00 (wake) -> 0E (start) -> 04 LL HH (speed) -> 10 02 (stop).

Frames from KS Fit WilinkProtocol disassembly. Belt WILL attempt to MOVE.
"""

import asyncio
import struct
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

CP = c.CHAR_CONTROL_POINT

START_WAKE = bytes([0x00])
START = bytes([0x0E])
PAUSE = bytes([0x10, 0x04])
STOP = bytes([0x10, 0x02])


def set_speed(kmh: float) -> bytes:
    v = int(kmh * 10)
    return bytes([0x04, v & 0xFF, (v >> 8) & 0xFF])


belt_moving = asyncio.Event()


async def main() -> None:
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data):
                print(f"!!! [{label}] {data.hex()}", flush=True)
                if label == "2acd" and len(data) >= 4:
                    if struct.unpack("<H", data[2:4])[0] > 0:
                        belt_moving.set()
            return handler

        for uuid, label, delay in [
            (c.CHAR_FITNESS_MACHINE_STATUS, "2ada", 0.10),
            (CP, "2ad9", 0.20),
            (c.CHAR_TREADMILL_DATA, "2acd", 0.30),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed", flush=True)

        print(">>> write 00 (wake)", flush=True)
        await client.write_gatt_char(CP, START_WAKE, response=True)
        await asyncio.sleep(0.5)
        print(">>> write 0E (START)", flush=True)
        await client.write_gatt_char(CP, START, response=True)

        print("waiting 10s for belt motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=10)
            print(">>> BELT MOVING <<<", flush=True)
        except asyncio.TimeoutError:
            print("no telemetry motion — trying speed anyway", flush=True)

        print(f">>> set speed 2.5: {set_speed(2.5).hex()}", flush=True)
        await client.write_gatt_char(CP, START_WAKE, response=True)
        await asyncio.sleep(0.3)
        await client.write_gatt_char(CP, set_speed(2.5), response=True)
        await asyncio.sleep(8)

        print(">>> STOP", flush=True)
        await client.write_gatt_char(CP, STOP, response=True)
        await asyncio.sleep(3)
        print("DONE", flush=True)


asyncio.run(main())
