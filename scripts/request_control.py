#!/usr/bin/env python3
"""Request FTMS control, then capture all notify traffic.

Sends ONE write: FTMS Request Control (0x00). Cannot move the belt.
"""

import asyncio
import struct
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c


def parse_treadmill_data(data: bytearray) -> dict:
    flags = struct.unpack("<H", data[:2])[0]
    i = 2
    out = {}
    if not (flags & 0x0004):
        out["speed_kmh"] = struct.unpack("<H", data[i : i + 2])[0] / 100
        i += 2
    if flags & 0x0002:
        out["avg_speed_kmh"] = struct.unpack("<H", data[i : i + 2])[0] / 100
        i += 2
    if flags & 0x0008:
        out["distance_m"] = int.from_bytes(data[i : i + 3], "little")
        i += 3
    if flags & 0x0080:
        out["elapsed_s"] = struct.unpack("<H", data[i : i + 2])[0]
        i += 2
    return out


async def main(listen_seconds: float) -> None:
    print("scanning...")
    device = None
    devices = await BleakScanner.discover(timeout=15)
    for d in devices:
        if d.name and d.name.startswith(c.DEVICE_NAME_PREFIX):
            device = d
            break
    if device is None:
        print("Z1 not found")
        sys.exit(1)
    print(f"found {device.name}")

    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                parsed = parse_treadmill_data(data) if "2acd" in label else ""
                print(f"[{label}] {data.hex()}  {parsed}", flush=True)
            return handler

        for service in client.services:
            for char in service.characteristics:
                if "notify" in char.properties or "indicate" in char.properties:
                    try:
                        await client.start_notify(char.uuid, make_handler(char.uuid[:13]))
                    except Exception as e:
                        print(f"sub fail {char.uuid[:13]}: {e}")

        print("sending Request Control (0x00)...", flush=True)
        try:
            await client.write_gatt_char(c.CHAR_CONTROL_POINT, bytes([0x00]), response=True)
            print("request control: accepted", flush=True)
        except Exception as e:
            print(f"request control failed: {e}", flush=True)

        print(f"listening {listen_seconds}s...", flush=True)
        await asyncio.sleep(listen_seconds)
        print("done", flush=True)


if __name__ == "__main__":
    asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 90.0))
