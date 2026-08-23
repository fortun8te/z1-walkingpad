"""Safety-gated experiment for speeds below the Z1's reported minimum."""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from dataclasses import asdict, dataclass

from z1_walkingpad_mcp.client import ControlRefused, Z1Error, Z1Treadmill


@dataclass
class ProbeResult:
    target_kmh: float
    ftms: str
    tunnel: str
    observed_speeds_kmh: list[float]
    distance_delta_m: float | None


async def wait_for_telemetry(treadmill: Z1Treadmill, timeout_s: float = 3.0) -> bool:
    event = asyncio.Event()

    def mark(_status) -> None:
        event.set()

    treadmill.on_status(mark)
    try:
        await asyncio.wait_for(event.wait(), timeout_s)
        return True
    except asyncio.TimeoutError:
        return False


async def observe(
    treadmill: Z1Treadmill,
    hold_s: float,
    start_distance_m: float | None,
) -> tuple[list[float], float | None]:
    event = asyncio.Event()
    treadmill.on_status(lambda _status: event.set())
    deadline = time.monotonic() + hold_s
    speeds: list[float] = []
    while time.monotonic() < deadline:
        try:
            await asyncio.wait_for(event.wait(), max(0.1, deadline - time.monotonic()))
        except asyncio.TimeoutError:
            pass
        event.clear()
        if treadmill.status.speed_kmh is not None:
            speeds.append(treadmill.status.speed_kmh)
        if treadmill.belt_running is False and speeds:
            await asyncio.sleep(1)
            break
    distance_delta = (
        None
        if start_distance_m is None or treadmill.status.distance_m is None
        else treadmill.status.distance_m - start_distance_m
    )
    return speeds, distance_delta


async def probe_speed(treadmill: Z1Treadmill, target_kmh: float, hold_s: float) -> ProbeResult:
    value = round(target_kmh * 100).to_bytes(2, "little")
    ftms_result = "not attempted"
    tunnel_result = "not attempted"

    try:
        await treadmill._ensure_control()
        await treadmill._pace("_last_cp_write", 0.4)
        await treadmill._cp_command(bytes([0x02]) + value)
        ftms_result = "accepted"
    except ControlRefused as error:
        ftms_result = f"refused code {error.result}"
    except Z1Error as error:
        ftms_result = f"error: {error}"

    if ftms_result != "accepted":
        try:
            await treadmill._vendor_control(0x02, value)
            tunnel_result = "accepted"
        except Z1Error as error:
            tunnel_result = f"error: {error}"

    start_distance = treadmill.status.distance_m
    speeds, distance_delta = await observe(treadmill, hold_s, start_distance)
    return ProbeResult(target_kmh, ftms_result, tunnel_result, speeds, distance_delta)


async def run(args: argparse.Namespace) -> int:
    treadmill = Z1Treadmill(args.name)
    await treadmill.connect()
    await treadmill.read_properties()
    print(json.dumps({
        "device": treadmill.device_name,
        "reported_range_kmh": [treadmill.min_speed, treadmill.max_speed],
        "properties": treadmill.properties,
    }, indent=2))

    targets = []
    current = args.max_kmh
    while current >= args.min_kmh - 0.0001:
        targets.append(round(current * 100) / 100)
        current -= args.step_kmh

    if not args.move:
        print("status-only probe; no belt movement attempted")
        print("planned targets:", ", ".join(f"{value:.2f}" for value in targets))
        await treadmill.disconnect()
        return 0

    results = []
    try:
        await treadmill.start()
        await asyncio.sleep(args.settle_s)
        for target in targets:
            result = await probe_speed(treadmill, target, args.hold_s)
            results.append(asdict(result))
            print(json.dumps(result))
            accepted = "accepted" in (result.ftms_result, result.tunnel_result)
            moved = any(speed > 0.05 for speed in result.observed_speeds_kmh)
            recent = result.observed_speeds_kmh[-3:] or [0]
            if accepted and moved and min(recent) < 0.05:
                print("belt appears to have stalled; stopping immediately")
                break
            if not accepted or not moved:
                break
    finally:
        try:
            await treadmill.stop()
        except Exception as error:
            print(f"emergency cleanup issue: {error}")
        await treadmill.disconnect()

    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", help="BLE name, for example KS-HD-Z1D")
    parser.add_argument("--min-kmh", type=float, default=0.40)
    parser.add_argument("--max-kmh", type=float, default=1.55)
    parser.add_argument("--step-kmh", type=float, default=0.10)
    parser.add_argument("--hold-s", type=float, default=8.0)
    parser.add_argument("--settle-s", type=float, default=5.0)
    parser.add_argument("--move", action="store_true", help="actually move the empty belt")
    parser.add_argument("--i-understand-run-empty-belt", action="store_true")
    args = parser.parse_args()

    if args.move and not args.i_understand_run_empty_belt:
        raise SystemExit("for a moving test add --i-understand-run-empty-belt; do not stand on the pad")
    if args.min_kmh < 0:
        raise SystemExit("minimum speed cannot be negative")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
