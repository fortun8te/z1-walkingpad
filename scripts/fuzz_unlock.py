#!/usr/bin/env python3
"""Fuzz candidate supplement unlock frames; oracle = ANY notification back.

Non-destructive: only property-list/unlock-shaped frames, no OTA, no FTMS writes.
"""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

SUPP_W = "24e2521c-f63b-48ed-85be-c5330d00fdf7"
SUPP_N = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
FFC2 = "0000ffc2-0000-1000-8000-00805f9b34fb"
FFF2 = "0000fff2-0000-1000-8000-00805f9b34fb"
FF01 = "0000ff01-0000-1000-8000-00805f9b34fb"

def wrap(body): return bytes(list(body) + [sum(body) & 0xFF])

MC21_MAGIC = bytes([0x01, 0x00, 0x0D, 0x00, 0x06, 0x0B, 0x0F, 0x0D])

CANDIDATES = [
    (SUPP_W, "mc21-magic-norsp", MC21_MAGIC),
    (SUPP_W, "proplist-wrap", wrap([0x20, 0, 0, 0])),
    (SUPP_W, "proplist-hdr", bytes([0x01, 0x00, 0x04, 0x00]) + wrap([0x20, 0, 0, 0])),
    (SUPP_W, "unlock-wrap", wrap([0x01])),
    (SUPP_W, "unlock-hdr", bytes([0x01, 0x00, 0x01, 0x00]) + wrap([0x01])),
    (SUPP_W, "sysinfo-wrap", wrap([0x02])),
    (SUPP_W, "getactions-wrap", wrap([0x03])),
    (FFC2, "ffc2-mc21-magic", MC21_MAGIC),
    (FFC2, "ffc2-proplist", wrap([0x20, 0, 0, 0])),
    (FFF2, "fff2-mc21-magic", MC21_MAGIC),
    (FF01, "ff01-mc21-magic", MC21_MAGIC),
]


async def main() -> None:
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    hits = 0
    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                nonlocal hits
                hits += 1
                print(f"!!! RESPONSE [{label}] {data.hex()}", flush=True)
            return handler

        for uuid, label, delay in [
            (c.CHAR_TREADMILL_DATA, "2acd", 0.10),
            (c.CHAR_FITNESS_MACHINE_STATUS, "2ada", 0.20),
            (SUPP_N, "supp", 0.30),
            ("0000ffc1-0000-1000-8000-00805f9b34fb", "ffc1", 0.10),
            ("0000fff1-0000-1000-8000-00805f9b34fb", "fff1", 0.10),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed; baseline listen 5s...", flush=True)
        await asyncio.sleep(5)
        print(f"baseline hits: {hits}\n", flush=True)

        for char, name, frame in CANDIDATES:
            before = hits
            print(f">>> [{name}] -> {char[:8]}: {frame.hex()}", flush=True)
            try:
                await client.write_gatt_char(char, frame, response=False)
            except Exception as e:
                print(f"    failed: {e}", flush=True)
            await asyncio.sleep(2.5)
            if hits > before:
                print(f"    ^^^ GOT {hits - before} RESPONSE(S) ^^^", flush=True)

        print(f"\ntotal notifications: {hits}", flush=True)


asyncio.run(main())
