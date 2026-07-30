#!/usr/bin/env python3
"""Read GAP Device Name (0x2A00) + connection params + verify unlock assumptions."""

import asyncio
import sys

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner

READS = {
    "00002a00-0000-1000-8000-00805f9b34fb": "GAP Device Name",
    "00002a01-0000-1000-8000-00805f9b34fb": "GAP Appearance",
    "00002a04-0000-1000-8000-00805f9b34fb": "Preferred Connection Params",
    "00002a23-0000-1000-8000-00805f9b34fb": "System ID",
    "00002a28-0000-1000-8000-00805f9b34fb": "Software Revision",
}


async def main() -> None:
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if not device:
        print("Z1 not found")
        return
    print(f"advertised name: {device.name!r}")
    print(f"advertised details: {device.details}", flush=True)

    scanner_devices = await BleakScanner.discover(timeout=6, return_adv=True)
    for a, (d, adv) in scanner_devices.items():
        if d.name and "KS-HD" in d.name:
            print(f"adv local_name={adv.local_name!r} mfr_data={adv.manufacturer_data} service_data={adv.service_data} tx_power={adv.tx_power}", flush=True)

    async with BleakClient(device, timeout=20) as client:
        for uuid, label in READS.items():
            try:
                val = await client.read_gatt_char(uuid)
                try:
                    printable = val.decode()
                except UnicodeDecodeError:
                    printable = val.hex()
                print(f"{label}: {val.hex()}  ({printable!r})", flush=True)
            except Exception as e:
                print(f"{label}: READ FAILED {e}", flush=True)


asyncio.run(main())
