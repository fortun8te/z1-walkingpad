"""CLI for the Z1 WalkingPad. Run: python -m z1_walkingpad_mcp <command>"""

from __future__ import annotations

import argparse
import asyncio
import sys

from .client import Z1Error, Z1Treadmill
from .config import GovernorConfig
from .governor import Governor


def fmt_status(t: Z1Treadmill) -> str:
    s = t.status
    return (
        f"speed={s.speed_kmh} km/h  distance={s.distance_m} m  "
        f"elapsed={s.elapsed_s} s  steps={t.steps_display}  kcal≈{t.calories.total_kcal:.1f}"
    )


async def cmd_status(args: argparse.Namespace) -> None:
    cfg = GovernorConfig.from_env()
    g = Governor(Z1Treadmill(args.name), config=cfg)
    t = g.treadmill
    await t.connect()
    print(f"governor: state={g.status_dict()['state']}  motion={'ON' if cfg.motion_enabled else 'OFF'}")
    print(f"connected to {t.device_name}, speed range {t.min_speed}-{t.max_speed} km/h")
    props = await t.read_properties()
    for pid, val in sorted(props.items()):
        print(f"  property {pid} = {val} ({val:#06x})")
    # grab a live telemetry sample
    event = asyncio.Event()
    t.on_status(lambda _s: event.set())
    try:
        await asyncio.wait_for(event.wait(), 3)
        print(fmt_status(t))
    except asyncio.TimeoutError:
        print("(no telemetry frame yet — belt stopped)")
    await t.disconnect()


async def cmd_start(args: argparse.Namespace) -> None:
    t = Z1Treadmill(args.name)
    t.on_status(lambda _s: print(fmt_status(t), flush=True))
    await t.connect()
    await t.start()
    print(f"belt started (min speed {t.min_speed} km/h)")
    if args.speed is not None:
        await asyncio.sleep(2)
        await t.set_speed(args.speed)
        print(f"speed set to {args.speed} km/h")
    if args.duration:
        await asyncio.sleep(args.duration)
        await t.stop()
        print("belt stopped")
    await t.disconnect()


async def cmd_stop(args: argparse.Namespace) -> None:
    t = Z1Treadmill(args.name)
    await t.connect()
    summary = await t.stop()
    print("belt stopped")
    print(f"session: {summary}")


async def cmd_nudge(args: argparse.Namespace) -> None:
    t = Z1Treadmill(args.name)
    t.on_status(lambda _s: print(fmt_status(t), flush=True))
    await t.connect()
    if args.command == "up":
        target = await t.speed_up(args.delta)
    else:
        target = await t.speed_down(args.delta)
    print(f"speed -> {target} km/h")
    await t.disconnect()


async def cmd_supervise(args: argparse.Namespace) -> None:
    cfg = GovernorConfig.from_env()
    g = Governor(Z1Treadmill(args.name), config=cfg)
    await g.treadmill.connect()
    print(f"connected — governor state={g.status_dict()['state']}  motion={'ON' if cfg.motion_enabled else 'OFF'}")
    if args.speed:
        target = await g.set_speed(args.speed)
        print(f"target speed: {target} km/h")
    g.treadmill.on_status(lambda s: print(fmt_status(g.treadmill), flush=True))
    if not cfg.motion_enabled:
        print("motion disabled — passive recording only. Set Z1_ENABLE_MOTION=1 to start the belt.")
        try:
            await asyncio.Event().wait()  # supervise telemetry until Ctrl-C
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
    else:
        await g.start()
        print("belt started — walking. Press Ctrl-C to stop.")
        try:
            while True:
                await asyncio.sleep(1)
                if g.fault.value != "none":
                    print(f"FAULT: {g.message} — belt stopped. Resume with 'resume'.")
                    break
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        summary = await g.stop()
        print(f"session complete: {summary}")
    await g.treadmill.disconnect()


async def main() -> int:
    parser = argparse.ArgumentParser(prog="z1-walkingpad", description=__doc__)
    parser.add_argument("--name", default=None, help="BLE name (default: scan for KS-HD-Z1*)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="connect, unlock, dump properties and one telemetry sample")

    p_sup = sub.add_parser("supervise", help="foreground supervised walk (Governor)")
    p_sup.add_argument("--speed", type=float, default=None, help="target speed override (km/h)")

    p_start = sub.add_parser("start", help="start the belt")
    p_start.add_argument("--speed", type=float, default=None, help="set speed (km/h) after start")
    p_start.add_argument("--duration", type=float, default=0, help="stop automatically after N seconds")

    sub.add_parser("stop", help="stop the belt and print the session summary")

    for name, help_text in (("up", "increase speed"), ("down", "decrease speed")):
        p_nudge = sub.add_parser(name, help=f"{help_text} (default 0.1 km/h)")
        p_nudge.add_argument("--delta", type=float, default=0.1, help="km/h step")

    args = parser.parse_args()
    handlers = {"status": cmd_status, "start": cmd_start, "stop": cmd_stop, "up": cmd_nudge,
                "down": cmd_nudge, "supervise": cmd_supervise}
    try:
        await handlers[args.command](args)
        return 0
    except Z1Error as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


def run() -> None:
    sys.exit(asyncio.run(main()))


if __name__ == "__main__":
    run()
