#!/usr/bin/env python3
"""THE test: KS Fit supplement handshake (propertyList + deviceUnlock) then FTMS control.

Frames recovered from KS Fit v5.9.10 disassembly (blutter):
  propertyList: E4 00 00 00 E4
  unlockCmd:    E2 00 0A RR T0..T3 CC   (T = u32(last 4 name chars as ASCII hex) + R)
  checksum:     sum(body) & 0xFF

Belt WILL attempt to MOVE. Keep clear.
"""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

SUPP_W = "24e2521c-f63b-48ed-85be-c5330d00fdf7"
SUPP_N = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
CP = c.CHAR_CONTROL_POINT

DEVICE_NAME = "KS-HD-Z1D"
R = 0x42


def wrap(body: list[int]) -> bytes:
    return bytes(body + [sum(body) & 0xFF])


PROPERTY_LIST = wrap([0xE4, 0x00, 0x00, 0x00])


def unlock_frame(name: str, r: int) -> bytes:
    last4 = name[-4:]
    t = int(last4.encode().hex(), 16) + r
    return wrap([0xE2, 0x00, 0x0A, r, t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF, (t >> 24) & 0xFF])


belt_moving = asyncio.Event()


async def main() -> None:
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    async with BleakClient(device, timeout=20) as client:
        def make_handler(label):
            def handler(_, data: bytearray) -> None:
                print(f"!!! [{label}] {data.hex()}", flush=True)
                if label == "2acd" and len(data) >= 4:
                    import struct
                    if struct.unpack("<H", data[2:4])[0] > 0:
                        belt_moving.set()
            return handler

        for uuid, label, delay in [
            (c.CHAR_FITNESS_MACHINE_STATUS, "2ada", 0.10),
            (CP, "2ad9", 0.20),
            (c.CHAR_TREADMILL_DATA, "2acd", 0.30),
            (SUPP_N, "supp", 0.10),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed\n", flush=True)

        print(f">>> propertyList: {PROPERTY_LIST.hex()}", flush=True)
        await client.write_gatt_char(SUPP_W, PROPERTY_LIST, response=False)
        await asyncio.sleep(2)

        uf = unlock_frame(DEVICE_NAME, R)
        print(f">>> unlock: {uf.hex()}", flush=True)
        await client.write_gatt_char(SUPP_W, uf, response=False)
        await asyncio.sleep(2)

        print(">>> REQUEST_CONTROL + START", flush=True)
        await client.write_gatt_char(CP, bytes([0x00]), response=True)
        await asyncio.sleep(1)
        await client.write_gatt_char(CP, bytes([0x07]), response=True)

        print("waiting 12s for belt motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=12)
            print(">>> BELT MOVING — setting 2.5 km/h for 8s <<<", flush=True)
            await client.write_gatt_char(CP, bytes([0x02, 0xFA, 0x00]), response=True)
            await asyncio.sleep(8)
        except asyncio.TimeoutError:
            print("no motion detected via telemetry", flush=True)

        await client.write_gatt_char(CP, bytes([0x08, 0x01]), response=True)
        print("STOP sent. DONE", flush=True)


asyncio.run(main())
