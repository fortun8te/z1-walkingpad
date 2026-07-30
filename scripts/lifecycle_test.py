#!/usr/bin/env python3
"""Full-lifecycle test: KS Fit connection sequence + supplement unlock handshake.

Belt WILL attempt to MOVE (start -> optional speed -> stop).
Run only with nobody on the pad, KS Fit app closed on all phones.
"""

import asyncio
import logging
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from z1_walkingpad_mcp import constants as c

logging.basicConfig(level=logging.DEBUG, format="%(name)s %(levelname)s %(message)s")
for noisy in ("bleak", "asyncio"):
    logging.getLogger(noisy).setLevel(logging.WARNING)

SUPPLEMENT_WRITE = "24e2521c-f63b-48ed-85be-c5330d00fdf7"
SUPPLEMENT_NOTIFY = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
MAGIC_PROPERTY_LIST = bytes([0x01, 0x00, 0x0D, 0x00, 0x06, 0x0B, 0x0F, 0x0D])

belt_moving = asyncio.Event()


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
                if label == "2acd" and len(data) >= 4:
                    import struct
                    speed = struct.unpack("<H", data[2:4])[0] / 100
                    if speed > 0:
                        belt_moving.set()
            return handler

        # KS Fit order: status, training, control point, treadmill data — staggered
        for uuid, label, delay in [
            (c.CHAR_FITNESS_MACHINE_STATUS, "2ada", 0.10),
            (c.CHAR_TRAINING_STATUS if hasattr(c, "CHAR_TRAINING_STATUS") else "00002ad3-0000-1000-8000-00805f9b34fb", "2ad3", 0.20),
            (c.CHAR_CONTROL_POINT, "2ad9", 0.30),
            (c.CHAR_TREADMILL_DATA, "2acd", 0.10),
            (SUPPLEMENT_NOTIFY, "supp", 0.10),
        ]:
            try:
                await client.start_notify(uuid, make_handler(label))
                print(f"subscribed {label}", flush=True)
            except Exception as e:
                print(f"SUB FAILED {label}: {e}", flush=True)
            await asyncio.sleep(delay)

        print("\nsending supplement magic (propertyList handshake)...", flush=True)
        try:
            await client.write_gatt_char(SUPPLEMENT_WRITE, MAGIC_PROPERTY_LIST, response=True)
            print("supplement write acked", flush=True)
        except Exception as e:
            print(f"supplement write failed: {e}", flush=True)
        await asyncio.sleep(1)

        async def cp(op: bytes, label: str) -> None:
            try:
                await client.write_gatt_char(c.CHAR_CONTROL_POINT, op, response=True)
                print(f"CP write acked: {label}", flush=True)
            except Exception as e:
                print(f"CP write FAILED {label}: {e}", flush=True)

        await cp(bytes([0x00]), "REQUEST_CONTROL")
        await asyncio.sleep(1)
        await cp(bytes([0x07]), "START_OR_RESUME")

        print("waiting up to 10s for belt motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=10)
            print(">>> BELT IS MOVING <<<", flush=True)
            await cp(bytes([0x02, 0xFA, 0x00]), "SET_SPEED 2.50")  # 250 = 2.50 km/h
            await asyncio.sleep(8)
        except asyncio.TimeoutError:
            print("belt never reported motion", flush=True)

        await cp(bytes([0x08, 0x01]), "STOP")
        await asyncio.sleep(3)
        print("DONE", flush=True)


asyncio.run(main())
