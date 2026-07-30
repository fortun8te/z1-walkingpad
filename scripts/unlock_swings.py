#!/usr/bin/env python3
"""Educated swings at the KS-HD-Z1D supplement unlock + FTMS start.

Tries candidate supplement frame encodings (propertyList / deviceUnlock),
then REQUEST_CONTROL + START_OR_RESUME. Belt may MOVE — keep clear.
"""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

SUPPLEMENT_WRITE = "24e2521c-f63b-48ed-85be-c5330d00fdf7"
SUPPLEMENT_NOTIFY = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
CP = c.CHAR_CONTROL_POINT

def wrap(body: list[int]) -> bytes:
    return bytes(body + [sum(body) & 0xFF])

CANDIDATES = [
    ("mc21-magic", bytes([0x01, 0x00, 0x0D, 0x00, 0x06, 0x0B, 0x0F, 0x0D])),
    ("propertyList-wrap", wrap([0x20, 0, 0, 0])),
    ("unlock-id1-wrap", wrap([0x01])),
    ("unlock-hdr", bytes([0x01, 0x00, 0x01, 0x00, 0x01, 0x02])),
    ("propertyList-hdr", bytes([0x01, 0x00, 0x04, 0x00, 0x20, 0, 0, 0, 0x20])),
]


async def main() -> None:
    print("scanning...", flush=True)
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                print(f"!!! [{label}] {data.hex()}", flush=True)
            return handler

        for uuid, label, delay in [
            (c.CHAR_FITNESS_MACHINE_STATUS, "2ada", 0.10),
            (CP, "2ad9", 0.20),
            (c.CHAR_TREADMILL_DATA, "2acd", 0.30),
            (SUPPLEMENT_NOTIFY, "supp", 0.10),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed all", flush=True)

        for name, frame in CANDIDATES:
            print(f"\n>>> supplement candidate [{name}]: {frame.hex()}", flush=True)
            try:
                await client.write_gatt_char(SUPPLEMENT_WRITE, frame, response=True)
                print("    acked", flush=True)
            except Exception as e:
                print(f"    write failed: {e}", flush=True)
            await asyncio.sleep(1.5)

        print("\n>>> REQUEST_CONTROL + START", flush=True)
        await client.write_gatt_char(CP, bytes([0x00]), response=True)
        await asyncio.sleep(1)
        await client.write_gatt_char(CP, bytes([0x07]), response=True)
        print("START sent — listening 12s (walk on it or watch for motion)", flush=True)
        await asyncio.sleep(12)
        await client.write_gatt_char(CP, bytes([0x08, 0x01]), response=True)
        print("STOP sent. DONE", flush=True)


asyncio.run(main())
