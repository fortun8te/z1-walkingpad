#!/usr/bin/env python3
"""Library-based control test using walkingpad-controller (mcdax).

Belt WILL MOVE: start (min speed) -> 2.5 km/h -> telemetry 15s -> stop.
Run only with nobody on the pad.
"""

import asyncio

from bleak import BleakScanner
from walkingpad_controller import WalkingPadController


async def main() -> None:
    print("scanning...", flush=True)
    device = await BleakScanner.find_device_by_name("KS-HD-Z1D", timeout=15)
    if device is None:
        print("Z1 not found")
        return
    print(f"found {device.name}", flush=True)

    controller = WalkingPadController(ble_device=device)
    controller.register_status_callback(
        lambda s: print(
            f"STATUS state={s.belt_state} speed={s.speed}km/h dist={s.distance}m "
            f"time={s.duration}s steps={s.steps} cal={s.calories}", flush=True)
    )
    controller.register_disconnect_callback(lambda: print("DISCONNECTED", flush=True))

    await controller.connect()
    print(f"protocol: {controller.protocol.value}", flush=True)
    print(f"speed range: {controller.min_speed}-{controller.max_speed} km/h, step {controller.speed_increment}", flush=True)
    print(f"firmware: {controller.firmware_version}", flush=True)

    print("\nSTARTING BELT...", flush=True)
    await controller.start()
    await asyncio.sleep(3)

    print("setting speed 2.5 km/h...", flush=True)
    await controller.set_speed(2.5)

    print("streaming telemetry 15s...", flush=True)
    await asyncio.sleep(15)

    print("STOPPING BELT...", flush=True)
    await controller.stop()
    await asyncio.sleep(3)
    await controller.disconnect()
    print("DONE", flush=True)


asyncio.run(main())
