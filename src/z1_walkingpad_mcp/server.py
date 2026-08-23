"""MCP server exposing Z1 WalkingPad control tools.

Run: python -m z1_walkingpad_mcp.server   (stdio transport)

Set Z1_WEIGHT_KG for accurate calorie estimates (default 75).
On stop, session summaries are appended to sessions.jsonl and written as
per-session JSON files in the sessions directory (default
~/.z1-walkingpad; override with Z1_SESSIONS_DIR — point it at an iCloud
Drive folder to feed the iOS Shortcut bridge, see docs/apple-health.md).
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from . import strava
from .client import Z1Error, Z1Treadmill
from .governor import Governor
from .session_recorder import recover_incomplete

mcp = MCPServer("z1-walkingpad")
_treadmill = Z1Treadmill()
governor = Governor(_treadmill)

SESSIONS_DIR = Path(os.environ.get("Z1_SESSIONS_DIR", Path.home() / ".z1-walkingpad"))
GOVERNOR_SESSIONS_DIR = governor.sessions_dir


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
    await governor.connect()
    await governor.start()
    if speed_kmh is not None:
        target = await governor.set_speed(speed_kmh)
        return f"belt started, ramping to {target} km/h"
    return f"belt started, ramping to {governor.config.default_speed_kmh} km/h"


@mcp.tool()
async def governor_status() -> dict:
    """Governor state machine: state, fault, target/current speed,
    distance/steps/step source, active session id."""
    if not _treadmill.connected:
        try:
            await governor.connect()
        except Exception:
            pass
    return governor.status_dict()


@mcp.tool()
async def governor_pause() -> str:
    """Pause the belt (session counters preserved; resume with governor_resume)."""
    await governor.pause()
    return "belt paused"


@mcp.tool()
async def governor_resume() -> str:
    """Manually clear a latched fault and/or restart ramping after pause."""
    result = await governor.resume()
    return "belt resumed" if result else "already running"


@mcp.tool()
async def governor_configure(max_speed_kmh: float | None = None,
                             default_speed_kmh: float | None = None) -> str:
    """Adjust Governor limits live. Speeds are clamped and validated."""
    overrides = {k: v for k, v in {
        "max_speed_kmh": max_speed_kmh, "default_speed_kmh": default_speed_kmh
    }.items() if v is not None}
    cfg = governor.configure(**overrides)
    return f"configured: max={cfg.max_speed_kmh} km/h, default={cfg.default_speed_kmh} km/h"


@mcp.tool()
async def sessions_recover() -> int:
    """Mark crash-interrupted session journals as incomplete-recovered.
    Returns count recovered."""
    paths = recover_incomplete(GOVERNOR_SESSIONS_DIR)
    return len(paths)


@mcp.tool()
async def sessions_list() -> list[dict]:
    """List recorded session summaries (newest first)."""
    files = sorted(GOVERNOR_SESSIONS_DIR.glob("*.ready.json"), reverse=True)
    out = []
    for f in files[:50]:
        try:
            data = json.loads(f.read_text())
            data["file"] = f.name
            out.append(data)
        except (OSError, json.JSONDecodeError):
            continue
    return out


@mcp.tool()
async def session_detail(session_id: str) -> dict:
    """Full summary for one session id."""
    path = GOVERNOR_SESSIONS_DIR / f"{session_id}.ready.json"
    if not path.exists():
        raise ValueError(f"unknown session {session_id}")
    return json.loads(path.read_text())


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
    The summary is appended to sessions.jsonl, written as a
    session-<timestamp>.json file, and uploaded to Strava if configured
    (see docs/strava.md) — the Strava iOS app then syncs it to Apple Health."""
    t = await _ensure_connected()
    summary = await t.stop()
    record = {"ended_at": int(time.time()), **summary}
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        with (SESSIONS_DIR / "sessions.jsonl").open("a") as f:
            f.write(json.dumps(record) + "\n")
        # per-session file for the iOS Shortcut / Apple Health bridge
        with (SESSIONS_DIR / f"session-{record['ended_at']}.json").open("w") as f:
            json.dump(record, f, indent=2)
    except OSError:
        pass
    # best-effort Strava upload — never let a sync failure break stop
    if strava.configured():
        try:
            activity_id = strava.upload_walk(summary, record["ended_at"])
            summary["strava_activity_id"] = activity_id
        except strava.StravaError as e:
            summary["strava_error"] = str(e)
    return summary


def run() -> None:
    try:
        mcp.run()
    except Z1Error as e:
        raise SystemExit(f"z1-walkingpad-mcp: {e}") from e


if __name__ == "__main__":
    run()
