#!/usr/bin/env python3
"""Connect INSTANTLY on advertisement (pairing-window theory), then full unlock + start.

Belt WILL attempt to MOVE. Keep clear.
"""

import asyncio
import struct
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError
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
found = asyncio.Event()
found_device = {}


def on_detect(device, adv):
    if device.name and device.name.startswith("KS-HD"):
        if not found.is_set():
            found.set()
            found_device["d"] = device
            print(f">>> PAD ADVERTISING (rssi {adv.rssi}) — connecting NOW", flush=True)


async def main() -> None:
    print("armed. waiting for pad to power on...", flush=True)
    scanner = BleakScanner(on_detect)
    await scanner.start()
    try:
        await asyncio.wait_for(found.wait(), timeout=120)
    except asyncio.TimeoutError:
        print("never saw the pad")
        return
    await scanner.stop()
    device = found_device["d"]

    async with BleakClient(device, timeout=20) as client:
        print("connected!", flush=True)

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
            try:
                await client.start_notify(uuid, make_handler(label))
            except Exception as e:
                print(f"sub fail {label}: {e}", flush=True)
            await asyncio.sleep(delay)

        uf = unlock_frame(DEVICE_NAME, R)
        print(f">>> propertyList: {PROPERTY_LIST.hex()}", flush=True)
        await client.write_gatt_char(SUPP_W, PROPERTY_LIST, response=False)
        await asyncio.sleep(1.5)
        print(f">>> unlock: {uf.hex()}", flush=True)
        await client.write_gatt_char(SUPP_W, uf, response=False)
        await asyncio.sleep(1.5)

        print(">>> REQUEST_CONTROL + START", flush=True)
        try:
            await client.write_gatt_char(CP, bytes([0x00]), response=True)
        except BleakError as e:
            print(f"rc err: {e}", flush=True)
        await asyncio.sleep(0.5)
        await client.write_gatt_char(CP, bytes([0x07]), response=True)

        print("waiting 15s for belt motion...", flush=True)
        try:
            await asyncio.wait_for(belt_moving.wait(), timeout=15)
            print(">>> BELT MOVING <<<", flush=True)
            await client.write_gatt_char(CP, bytes([0x02, 0xFA, 0x00]), response=True)
            await asyncio.sleep(8)
        except asyncio.TimeoutError:
            print("no motion", flush=True)

        await client.write_gatt_char(CP, bytes([0x08, 0x01]), response=True)
        print("STOP sent. DONE", flush=True)


asyncio.run(main())
