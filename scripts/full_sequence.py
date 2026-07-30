#!/usr/bin/env python3
"""Full KS Fit replication: reads + propertyList + unlock + manual mode + FTMS start.

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
TRAINING_STATUS = "00002ad3-0000-1000-8000-00805f9b34fb"
FM_STATUS = c.CHAR_FITNESS_MACHINE_STATUS
FEATURE = "00002acc-0000-1000-8000-00805f9b34fb"

DEVICE_NAME = "KS-HD-Z1D"
R = 0x42


def wrap(body):
    return bytes(body + [sum(body) & 0xFF])


PROPERTY_LIST = wrap([0xE4, 0x00, 0x00, 0x00])
SET_MODE_MANUAL = wrap([0xE4, 0x02, 0x03, 0x0A, 0x01, 0x00])


def unlock_frame(name, r):
    t = int(name[-4:].encode().hex(), 16) + r
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
            def handler(_, data):
                print(f"!!! [{label}] {data.hex()}", flush=True)
                if label == "2acd" and len(data) >= 4:
                    import struct
                    if struct.unpack("<H", data[2:4])[0] > 0:
                        belt_moving.set()
            return handler

        import struct
        feat = await client.read_gatt_char(FEATURE)
        print(f"machine features: {feat.hex()}", flush=True)
        ts = await client.read_gatt_char(TRAINING_STATUS)
        print(f"training status (2ad3): {ts.hex()}", flush=True)
        fms = await client.read_gatt_char(FM_STATUS)
        print(f"machine status (2ada): {fms.hex()}", flush=True)

        for uuid, label, delay in [
            (FM_STATUS, "2ada", 0.10),
            (CP, "2ad9", 0.20),
            (c.CHAR_TREADMILL_DATA, "2acd", 0.30),
            (SUPP_N, "supp", 0.10),
        ]:
            await client.start_notify(uuid, make_handler(label))
            await asyncio.sleep(delay)
        print("subscribed\n", flush=True)

        uf = unlock_frame(DEVICE_NAME, R)
        for label, frame, resp in [
            ("propertyList", PROPERTY_LIST, True),
            ("unlock", uf, True),
            ("set mode manual", SET_MODE_MANUAL, True),
        ]:
            print(f">>> {label}: {frame.hex()} (response={resp})", flush=True)
            await client.write_gatt_char(SUPP_W, frame, response=resp)
            await asyncio.sleep(3)

        print(">>> REQUEST_CONTROL + START", flush=True)
        await client.write_gatt_char(CP, bytes([0x00]), response=True)
        await asyncio.sleep(1)
        await client.write_gatt_char(CP, bytes([0x07]), response=True)

        print("waiting 12s for belt motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=12)
            print(">>> BELT MOVING <<<", flush=True)
            await client.write_gatt_char(CP, bytes([0x02, 0xFA, 0x00]), response=True)
            await asyncio.sleep(8)
        except asyncio.TimeoutError:
            print("no motion", flush=True)

        await client.write_gatt_char(CP, bytes([0x08, 0x01]), response=True)
        print("STOP sent. DONE", flush=True)


asyncio.run(main())
