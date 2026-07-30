"""MCP server exposing Z1 WalkingPad control tools.

Run: python -m z1_walkingpad_mcp.server   (stdio transport)

Set Z1_WEIGHT_KG for accurate calorie estimates (default 75).
Session summaries are appended to ~/.z1-walkingpad/sessions.jsonl on stop.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from .client import Z1Error, Z1Treadmill

mcp = MCPServer("z1-walkingpad")
_treadmill = Z1Treadmill()

HISTORY_FILE = Path.home() / ".z1-walkingpad" / "sessions.jsonl"


async def _ensure_connected() -> Z1Treadmill:
    if not _treadmill.connected:
        await _treadmill.connect()
    return _treadmill


@mcp.tool()
async def treadmill_status() -> dict:
    """Live treadmill state: current speed, session distance/time/steps,
    estimated calories burned (MET formula, set Z1_WEIGHT_KG), speed range."""
    t = await _ensure_connected()
    await t.read_properties()
    s = t.status
    return {
        "device": t.device_name,
        "speed_kmh": s.speed_kmh,
        "belt_running": bool(s.speed_kmh and s.speed_kmh > 0),
        "session": t.session_summary(),
        "speed_range_kmh": [t.min_speed, t.max_speed],
    }


@mcp.tool()
async def treadmill_start(speed_kmh: float | None = None) -> str:
    """Start the belt. Optionally set a target speed right after starting.
    The belt always ramps up from the minimum speed (1.6 km/h).
    Resets the session counters (distance/time/steps/calories)."""
    t = await _ensure_connected()
    await t.start()
    if speed_kmh is not None:
        await t.set_speed(speed_kmh)
        return f"belt started, speed set to {speed_kmh} km/h"
    return f"belt started at minimum speed ({t.min_speed} km/h)"


@mcp.tool()
async def treadmill_set_speed(speed_kmh: float) -> str:
    """Set belt speed in km/h (1.6-6.4). Belt must be running."""
    t = await _ensure_connected()
    await t.set_speed(speed_kmh)
    return f"speed set to {speed_kmh} km/h"


@mcp.tool()
async def treadmill_speed_up(delta_kmh: float = 0.1) -> str:
    """Increase belt speed (default +0.1 km/h, the pad's native step)."""
    t = await _ensure_connected()
    target = await t.speed_up(delta_kmh)
    return f"speed -> {target} km/h"


@mcp.tool()
async def treadmill_speed_down(delta_kmh: float = 0.1) -> str:
    """Decrease belt speed (default -0.1 km/h, the pad's native step)."""
    t = await _ensure_connected()
    target = await t.speed_down(delta_kmh)
    return f"speed -> {target} km/h"


@mcp.tool()
async def treadmill_pause() -> str:
    """Pause the belt (keeps session stats; resume with treadmill_start)."""
    t = await _ensure_connected()
    await t.pause()
    return "belt paused"


@mcp.tool()
async def treadmill_stop() -> dict:
    """Stop the belt, end the session, and return its summary:
    duration, distance, steps, average speed, estimated calories.
    The summary is appended to ~/.z1-walkingpad/sessions.jsonl."""
    t = await _ensure_connected()
    summary = await t.stop()
    record = {"ended_at": int(time.time()), **summary}
    try:
        HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        with HISTORY_FILE.open("a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass
    return summary


def run() -> None:
    try:
        mcp.run()
    except Z1Error as e:
        raise SystemExit(f"z1-walkingpad-mcp: {e}") from e


if __name__ == "__main__":
    run()
