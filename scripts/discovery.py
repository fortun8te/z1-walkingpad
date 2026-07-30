#!/usr/bin/env python3
"""Read-only discovery: find the Z1, dump device info, stream telemetry.

Sends ZERO writes to the device. Safe to run while the belt is in use.
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
    print(f"Scanning for {c.DEVICE_NAME_PREFIX}* ...")
    device = await BleakScanner.find_device_by_name(c.DEVICE_NAME_PREFIX, timeout=15)
    if device is None:
        devices = await BleakScanner.discover(timeout=8)
        for d in devices:
            if d.name and d.name.startswith(c.DEVICE_NAME_PREFIX):
                device = d
                break
    if device is None:
        print("Z1 not found. Is it powered on? Is the phone app disconnected?")
        sys.exit(1)

    print(f"Found {device.name} at {device.address}\n")

    async with BleakClient(device, timeout=20) as client:
        for label, char in [
            ("manufacturer", c.CHAR_MANUFACTURER),
            ("model", c.CHAR_MODEL),
            ("firmware", c.CHAR_FIRMWARE),
            ("hardware", c.CHAR_HARDWARE),
        ]:
            val = await client.read_gatt_char(char)
            print(f"{label}: {val.decode(errors='replace').strip()}")

        sr = await client.read_gatt_char(c.CHAR_SUPPORTED_SPEED_RANGE)
        mn, mx, step = struct.unpack("<HHH", sr[:6])
        print(f"supported speed: {mn/100:.2f} - {mx/100:.2f} km/h, step {step/100:.2f}")

        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                parsed = parse_treadmill_data(data) if "2acd" in label else {}
                print(f"[{label}] {data.hex()}  {parsed if parsed else ''}")
            return handler

        subscribed = []
        for service in client.services:
            for char in service.characteristics:
                if "notify" in char.properties or "indicate" in char.properties:
                    try:
                        await client.start_notify(char.uuid, make_handler(char.uuid[:13]))
                        subscribed.append(char.uuid[:13])
                    except Exception as e:
                        print(f"could not subscribe {char.uuid[:13]}: {e}")
        print(f"subscribed to: {subscribed}")
        print(f"\nListening for {listen_seconds}s (read-only)...\n")
        await asyncio.sleep(listen_seconds)


if __name__ == "__main__":
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    asyncio.run(main(seconds))
