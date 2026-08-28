# ruff: noqa: I001
"""Read-only Z1 auto-mode probe.

This script connects, performs the normal vendor unlock handshake, reads the
device properties, and reports the hidden mode value.  It deliberately never
writes property 10, never requests FTMS control, and never starts the belt.

The mode value is interesting because generic KingSmith firmware labels
property 10 values 0/1/2 as manual/auto/sleep.  That label is not proof that
this Z1 has the front/back sensors needed for automatic speed control.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from dataclasses import asdict, dataclass

from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError

sys.path.insert(0, "src")

from z1_walkingpad_mcp import constants as c
from z1_walkingpad_mcp import protocol as p


PROP_MODE = 10
MODE_MASK = 0x00E0
MODE_SHIFT = 5
MODE_NAMES = {0: "manual", 1: "auto", 2: "sleep"}
MOTION_EPSILON_KMH = 0.05


@dataclass
class ProbeResult:
    device_name: str
    address: str
    properties: dict[int, int]
    mode_raw: int | None
    mode_index: int | None
    mode_name: str
    belt_seen_moving: bool
    motion_samples: list[float]
    machine_status: int | None
    idle_gate_passed: bool
    auto_mode_write: str = "not attempted (read-only probe)"


def decode_mode(value: int | None) -> tuple[int | None, str]:
    """Decode property 10 without assuming the mode is supported by the Z1."""
    if value is None:
        return None, "not reported"
    index = (value & MODE_MASK) >> MODE_SHIFT
    return index, MODE_NAMES.get(index, f"unknown ({index})")


def mode_value_for_auto(current: int) -> int:
    """Return the candidate value for a future test; never sends it."""
    return (current & ~MODE_MASK) | (1 << MODE_SHIFT)


def parse_speed(data: bytes) -> float | None:
    """Read instantaneous speed from a treadmill-data packet, if present."""
    parsed = p.parse_treadmill_data(data)
    return parsed.speed_kmh


def idle_gate_passed(
    motion_samples: list[float], machine_status: int | None, belt_seen_moving: bool
) -> bool:
    """Return true only when the available signals explicitly say idle.

    A silent telemetry stream is not treated as proof of idle.  The direct
    machine-status read must report one of the Z1's stopped states (0x01 or
    0x02), and no speed/status callback may have shown motion.
    """
    return (
        machine_status in (0x01, 0x02)
        and not belt_seen_moving
        and all(speed <= MOTION_EPSILON_KMH for speed in motion_samples)
    )


async def find_device(name: str | None, timeout: float) -> object:
    if name:
        device = await BleakScanner.find_device_by_name(name, timeout=timeout)
    else:
        device = await BleakScanner.find_device_by_filter(
            lambda d, _ad: (d.name or "").startswith(c.DEVICE_NAME_PREFIX),
            timeout=timeout,
        )
    if device is None:
        raise RuntimeError(
            f"{c.DEVICE_NAME_PREFIX}* not found; power on the pad and close KS Fit/other controllers"
        )
    return device


async def probe(name: str | None, scan_timeout: float, idle_guard_s: float) -> ProbeResult:
    device = await find_device(name, scan_timeout)
    motion_samples: list[float] = []
    moving = False
    machine_status: int | None = None
    supplement_ready = asyncio.Event()
    vendor_replies: asyncio.Queue[tuple[int, int, bytes]] = asyncio.Queue()

    def on_supplement(_char, data: bytearray) -> None:
        raw = bytes(data)
        if p.is_unlock_ok(raw):
            supplement_ready.set()
        parsed = p.parse_frame(raw)
        if parsed is not None:
            vendor_replies.put_nowait(parsed)

    def on_treadmill_data(_char, data: bytearray) -> None:
        nonlocal moving
        speed = parse_speed(bytes(data))
        if speed is not None:
            motion_samples.append(speed)
            moving = moving or speed > MOTION_EPSILON_KMH

    def on_machine_status(_char, data: bytearray) -> None:
        nonlocal moving
        # 0x04 is the Z1's started event.  This is a second motion signal,
        # useful when the treadmill-data stream is sparse.
        if data and data[0] == 0x04:
            moving = True

    async with BleakClient(device, timeout=20) as client:
        # Notifications are enabled before the unlock write.  No FTMS control
        # point is touched, so this cannot claim control or move the belt.
        await client.start_notify(c.CHAR_SUPPLEMENT_NOTIFY, on_supplement)
        await client.start_notify(c.CHAR_TREADMILL_DATA, on_treadmill_data)
        await client.start_notify(c.CHAR_FITNESS_MACHINE_STATUS, on_machine_status)

        await client.write_gatt_char(
            c.CHAR_SUPPLEMENT_WRITE,
            p.unlock_frame(device.name or c.DEVICE_NAME_PREFIX),
            response=False,
        )
        try:
            await asyncio.wait_for(supplement_ready.wait(), c.UNLOCK_TIMEOUT_S)
        except asyncio.TimeoutError as exc:
            raise RuntimeError("vendor unlock timed out") from exc

        # SYS_INFO is the normal post-unlock initialization frame.  It is not
        # a control command and does not alter settings.
        await client.write_gatt_char(
            c.CHAR_SUPPLEMENT_WRITE,
            p.sysinfo_frame(0),
            response=False,
        )
        await asyncio.sleep(c.VENDOR_MIN_INTERVAL_S)

        await client.write_gatt_char(
            c.CHAR_SUPPLEMENT_WRITE,
            p.setting_get_frame(0),
            response=False,
        )
        properties: dict[int, int] | None = None
        deadline = asyncio.get_running_loop().time() + c.VENDOR_RESPONSE_TIMEOUT_S
        while asyncio.get_running_loop().time() < deadline:
            remaining = max(0.05, deadline - asyncio.get_running_loop().time())
            try:
                cmd0, cmd1, data = await asyncio.wait_for(vendor_replies.get(), remaining)
            except asyncio.TimeoutError:
                break
            if cmd0 == c.VOP_PROPERTY and cmd1 == 0x80:
                properties = p.parse_property_records(data)
                break
        if properties is None:
            raise RuntimeError("property read timed out")

        # Explicit motion gate: never proceed with an experimental action if
        # any observed speed/status says the belt is running.  This probe has
        # no experimental action, but the result makes the gate auditable.
        await asyncio.sleep(max(0.0, idle_guard_s))
        try:
            status_data = bytes(await client.read_gatt_char(c.CHAR_FITNESS_MACHINE_STATUS))
            machine_status = status_data[0] if status_data else None
            if machine_status == 0x04:
                moving = True
        except (BleakError, OSError, asyncio.TimeoutError):
            # Some Z1 firmware exposes status as notify-only.  Unknown is
            # deliberately not considered safe for a future write.
            machine_status = None
        mode_raw = properties.get(PROP_MODE)
        mode_index, mode_name = decode_mode(mode_raw)
        return ProbeResult(
            device_name=device.name or c.DEVICE_NAME_PREFIX,
            address=str(device.address),
            properties=properties,
            mode_raw=mode_raw,
            mode_index=mode_index,
            mode_name=mode_name,
            belt_seen_moving=moving,
            motion_samples=motion_samples,
            machine_status=machine_status,
            idle_gate_passed=idle_gate_passed(motion_samples, machine_status, moving),
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", help="exact BLE name, usually KS-HD-Z1D")
    parser.add_argument("--scan-timeout", type=float, default=15.0)
    parser.add_argument("--idle-guard-s", type=float, default=2.0)
    args = parser.parse_args()
    try:
        result = asyncio.run(probe(args.name, args.scan_timeout, args.idle_guard_s))
    except (OSError, RuntimeError) as exc:
        print(f"probe failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    print("READ-ONLY: property 10 was not written; no FTMS control command was sent.")


if __name__ == "__main__":
    main()
