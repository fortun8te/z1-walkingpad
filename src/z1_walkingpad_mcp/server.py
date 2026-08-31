"""MCP server exposing Z1 WalkingPad control tools.

Run: python -m z1_walkingpad_mcp.server   (stdio transport)

Set Z1_WEIGHT_KG for accurate calorie estimates (default 75).
On stop, session summaries are appended to sessions.jsonl and validated
Health queue files are written to iCloud Drive automatically on macOS (or a
local subfolder elsewhere). Override with Z1_HEALTH_QUEUE_DIR if needed; see
docs/apple-health.md.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
import uuid
import sys
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from . import strava
from .client import Z1Error, Z1Treadmill
from .governor import Governor
from .health_automation import trigger_health_shortcut
from .health_export import build_health_record
from .highscores import compute_achievements, compute_highscores, export_agent_data, write_agent_export
from .session_recorder import recover_incomplete

mcp = MCPServer("z1-walkingpad")
_treadmill = Z1Treadmill()
governor = Governor(_treadmill)

SESSIONS_DIR = Path(os.environ.get("Z1_SESSIONS_DIR", Path.home() / ".z1-walkingpad"))
GOVERNOR_SESSIONS_DIR = governor.sessions_dir
HEALTH_ROUTE = os.environ.get("Z1_HEALTH_ROUTE", "shortcut").strip().lower()
# The Shortcuts app's own iCloud container -- the folder the Files app shows as
# "iCloud Drive > Shortcuts". The Shortcuts "Get File" action resolves its path
# relative to THIS folder, not to the iCloud Drive root, so a queue written
# anywhere else is invisible to the iPhone Shortcut.
_DEFAULT_HEALTH_QUEUE = (
    Path.home()
    / "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents"
    / "z1-walkingpad/health-queue"
    if sys.platform == "darwin"
    else SESSIONS_DIR / "health-queue"
)
HEALTH_QUEUE_DIR = Path(os.environ.get("Z1_HEALTH_QUEUE_DIR", _DEFAULT_HEALTH_QUEUE))


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
        except Exception:  # BLE connect can raise many transport errors
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
    files = sorted(GOVERNOR_SESSIONS_DIR.glob("session-*.json"), reverse=True)
    out = []
    for f in files[:10]:
        try:
            data = json.loads(f.read_text())
            out.append({
                "id": data.get("session_id") or f.stem,
                "m": data.get("distance_m"),
                "s": data.get("active_duration_s") or data.get("duration_s"),
                "steps": data.get("steps"),
                "kcal": data.get("calories_kcal"),
            })
        except (OSError, json.JSONDecodeError):
            continue
    if out:
        return out
    from .highscores import export_agent_data
    return export_agent_data(GOVERNOR_SESSIONS_DIR).get("recent", [])


@mcp.tool()
async def session_detail(session_id: str) -> dict:
    """Full summary for one session id."""
    path = GOVERNOR_SESSIONS_DIR / f"session-{session_id}.json"
    if not path.exists():
        raise ValueError(f"unknown session {session_id}")
    return json.loads(path.read_text())


@mcp.tool()
async def highscores() -> dict:
    """Highscores: longest walk, farthest, most steps/kcal (single walk + best day), streaks, totals. Agent-readable."""
    return compute_highscores(GOVERNOR_SESSIONS_DIR)

@mcp.tool()
async def achievements() -> list[dict]:
    """Achievements / badges: unlocked + progress 0..1 for each."""
    return compute_achievements(GOVERNOR_SESSIONS_DIR)

@mcp.tool()
async def daily_totals(days: int = 7) -> list[dict]:
    """Daily aggregates for last N days (default 7, max 90)."""
    days = max(1, min(int(days), 90))
    hs = compute_highscores(GOVERNOR_SESSIONS_DIR)
    return hs.get("daily_aggregates", [])[-days:]

@mcp.tool()
async def agent_data() -> dict:
    """Compact totals + last 8 walks. Use this instead of dumping history."""
    data = export_agent_data(GOVERNOR_SESSIONS_DIR)
    try:
        write_agent_export(GOVERNOR_SESSIONS_DIR)
    except OSError:
        pass
    return data


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
    The summary is appended to sessions.jsonl and sent through exactly one
    Health route: the iPhone Shortcut queue by default, or Strava only when
    Z1_HEALTH_ROUTE=strava is explicitly configured."""
    t = await _ensure_connected()
    has_session = governor.session_id is not None or t.session_clock.started_at is not None
    if not has_session:
        return {"health_export_skipped": "no active session"}
    summary = await governor.stop() if governor.session_id is not None else await t.stop()
    ended_at = time.time()
    session_id = uuid.uuid4().hex
    record = {"session_id": session_id, "ended_at": ended_at, **summary}
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        with (SESSIONS_DIR / "sessions.jsonl").open("a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass

    # Use exactly one Health route.  A successful Strava upload suppresses
    # the Shortcut queue item; otherwise the validated file is the fallback.
    strava_uploaded = False
    if HEALTH_ROUTE == "strava" and strava.configured():
        try:
            activity_id = strava.upload_walk(summary, int(ended_at))
            summary["strava_activity_id"] = activity_id
            strava_uploaded = True
        except strava.StravaError as e:
            summary["strava_error"] = str(e)
    elif HEALTH_ROUTE == "strava":
        summary["strava_error"] = "Strava route selected but not configured"

    health_record = build_health_record(summary, ended_at, session_id)
    health_queued = False
    if not strava_uploaded and health_record is not None:
        try:
            HEALTH_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(dir=HEALTH_QUEUE_DIR, suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(health_record, f, indent=2)
                os.replace(tmp_name, HEALTH_QUEUE_DIR / f"health-{session_id}.json")
                health_queued = True
            except BaseException:
                try:
                    os.unlink(tmp_name)
                except OSError:
                    pass
                raise
        except OSError:
            summary["health_export_error"] = "could not write Health queue file"
    elif not strava_uploaded:
        summary["health_export_skipped"] = "session too short or invalid"
    if health_queued:
        automation = trigger_health_shortcut()
        if automation is not None:
            summary["health_automation"] = automation
    try:
        write_agent_export(GOVERNOR_SESSIONS_DIR)
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
