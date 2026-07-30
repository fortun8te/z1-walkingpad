#!/usr/bin/env python3
"""Diagnostic: verify CCCD writes stick, look for encryption/pairing gates."""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c


async def main() -> None:
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    async with BleakClient(device, timeout=20) as client:
        print("connected\n", flush=True)
        for service in client.services:
            for char in service.characteristics:
                for desc in char.descriptors:
                    try:
                        val = await client.read_gatt_descriptor(desc.handle)
                        print(f"{char.uuid[:8]} desc {desc.uuid[:8]} (handle {desc.handle}) = {val.hex()}", flush=True)
                    except Exception as e:
                        print(f"{char.uuid[:8]} desc {desc.uuid[:8]} read FAILED: {e}", flush=True)

        print("\nsubscribing to 2acd...", flush=True)
        await client.start_notify(c.CHAR_TREADMILL_DATA, lambda s, d: print(f"NOTIFY {d.hex()}", flush=True))
        await asyncio.sleep(0.5)

        for service in client.services:
            for char in service.characteristics:
                if char.uuid.startswith("00002acd"):
                    for desc in char.descriptors:
                        val = await client.read_gatt_descriptor(desc.handle)
                        print(f"2acd CCCD after subscribe = {val.hex()}  ({'NOTIFY ON' if val[0] & 1 else 'NOTIFY OFF!'})", flush=True)

        print("\nlistening 5s...", flush=True)
        await asyncio.sleep(5)
        print("done", flush=True)


asyncio.run(main())
