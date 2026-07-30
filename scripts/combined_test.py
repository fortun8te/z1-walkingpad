#!/usr/bin/env python3
"""Combined: supplement propertyList -> unlock -> vendor wake+start via 2AD9.

Belt WILL attempt to MOVE. Keep clear.
"""

import asyncio
import struct
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

SUPP_W = "24e2521c-f63b-48ed-85be-c5330d00fdf7"
SUPP_N = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
CP = c.CHAR_CONTROL_POINT
DEVICE_NAME = "KS-HD-Z1D"
R = 0x42


def wrap(body):
    return bytes(body + [sum(body) & 0xFF])


PROPERTY_LIST = wrap([0xE4, 0x00, 0x00, 0x00])


def unlock_frame(name, r):
    t = int(name[-4:].encode().hex(), 16) + r
    return wrap([0xE2, 0x00, 0x0A, r, t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF, (t >> 24) & 0xFF])


belt_moving = asyncio.Event()


async def cp(client, data, label):
    try:
        await client.write_gatt_char(CP, data, response=True)
        print(f"    CP acked: {label} ({data.hex()})", flush=True)
    except Exception as e:
        print(f"    CP FAILED {label}: {e}", flush=True)


async def main() -> None:
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15)
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
            (SUPP_N, "supp", 0.10),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed\n", flush=True)

        uf = unlock_frame(DEVICE_NAME, R)
        print(">>> supplement propertyList", flush=True)
        await client.write_gatt_char(SUPP_W, PROPERTY_LIST, response=False)
        await asyncio.sleep(2)
        print(f">>> supplement unlock {uf.hex()}", flush=True)
        await client.write_gatt_char(SUPP_W, uf, response=False)
        await asyncio.sleep(2)

        print(">>> CP: 00 (wake)", flush=True)
        await cp(client, bytes([0x00]), "wake")
        await asyncio.sleep(0.5)
        print(">>> CP: 0E (START)", flush=True)
        await cp(client, bytes([0x0E]), "vendor start")

        print("waiting 10s for motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=10)
            print(">>> BELT MOVING <<<", flush=True)
        except asyncio.TimeoutError:
            print("no motion; trying FTMS 07 too", flush=True)
            await cp(client, bytes([0x07]), "ftms start")
            try:
                await asyncio.wait_for(belt_moving.wait(), timeout=8)
                print(">>> BELT MOVING (FTMS) <<<", flush=True)
            except asyncio.TimeoutError:
                print("still no motion", flush=True)

        print(">>> speed 2.5", flush=True)
        await cp(client, bytes([0x04, 0x19, 0x00]), "vendor speed 2.5")
        await asyncio.sleep(6)

        print(">>> stop", flush=True)
        await cp(client, bytes([0x10, 0x02]), "vendor stop")
        await cp(client, bytes([0x08, 0x01]), "ftms stop")
        await asyncio.sleep(2)
        print("DONE", flush=True)


asyncio.run(main())
