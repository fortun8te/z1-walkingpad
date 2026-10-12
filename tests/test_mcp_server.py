"""Current read-only MCP contract. All session reads use temporary fixtures."""
import importlib
import os
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import subprocess
import sys

import pytest

from z1_walkingpad_mcp import server


@pytest.fixture(autouse=True)
def isolated_home(tmp_path_factory, monkeypatch):
    """The server falls back to ~/Library/Application Support/Z1 WalkingPad.
    No test may ever see the real folder, so HOME points at an empty directory."""
    monkeypatch.setenv("HOME", str(tmp_path_factory.mktemp("home")))
    monkeypatch.delenv("Z1_SESSIONS_DIR", raising=False)


def snapshot(tmp_path, monkeypatch, **changes):
    data = dict(schema=1, updatedAt=datetime.now(timezone.utc).isoformat(),
                connected=True, beltRunning=True, speedKmh=3.2,
                distanceM=267, elapsedSec=300, steps=418,
                caloriesKcal=19.25, todayKcal=87.5, todaySteps=2400,
                todayDistanceM=1600, todayMinutes=30)
    data.update(changes)
    (tmp_path / "live.json").write_text(json.dumps(data))
    (tmp_path / "sessions.json").write_text("[]")
    monkeypatch.setenv("Z1_SESSIONS_DIR", str(tmp_path))
    return data


def test_live_calories_are_session_calories(tmp_path, monkeypatch):
    snapshot(tmp_path, monkeypatch)
    assert server._live()["kcal"] == 19.2
    assert server._today()["kcal"] == 87.5


def test_old_schema_one_missing_calories_is_unknown(tmp_path, monkeypatch):
    data = snapshot(tmp_path, monkeypatch)
    del data["caloriesKcal"]
    (tmp_path / "live.json").write_text(json.dumps(data))
    assert server._live()["kcal"] is None


def test_disconnected_updated_totals(tmp_path, monkeypatch):
    snapshot(tmp_path, monkeypatch, connected=False, beltRunning=False,
             speedKmh=0, todaySteps=2500)
    assert server._live()["connected"] is False
    assert server._today()["steps"] == 2500
    assert "kmh" not in server._today()


def test_stale_snapshot_does_not_override_history(tmp_path, monkeypatch):
    snapshot(tmp_path, monkeypatch,
             updatedAt=(datetime.now(timezone.utc)-timedelta(minutes=5)).isoformat())
    assert server._live() is None
    assert server._today()["steps"] == 0


def test_entrypoints_resolve_to_read_only_server():
    root = Path(__file__).resolve().parents[1]
    config = (root / "pyproject.toml").read_text()
    for command in ("z1-walkingpad", "z1-walkingpad-mcp"):
        target = re.search(r'^' + re.escape(command) + r' = "([^"]+)"$', config, re.MULTILINE).group(1)
        module, function = target.split(":")
        assert getattr(importlib.import_module(module), function) is server.run


def test_removed_control_command_fails_without_starting_server():
    result = subprocess.run([sys.executable, "-m", "z1_walkingpad_mcp", "start", "--speed", "2.5"],
                            capture_output=True, text=True, timeout=10,
                            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")})
    assert result.returncode == 2
    assert "unrecognized arguments" in result.stderr


def test_module_help_describes_read_only_role():
    result = subprocess.run([sys.executable, "-m", "z1_walkingpad_mcp", "--help"],
                            capture_output=True, text=True, timeout=10,
                            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")})
    assert result.returncode == 0
    assert "Read-only" in result.stdout


# --- audit: local-day boundaries and the live merge --------------------------
# Each test below fails on the server the audit described (UTC text prefix for
# the day, live run replacing the day's total, root fixed at import time).

import time as _time
from datetime import date as _real_date


def point_at(tmp_path, monkeypatch):
    monkeypatch.setenv("Z1_SESSIONS_DIR", str(tmp_path))
    if hasattr(server, "ROOT"):  # the audited server resolved its folder at import
        monkeypatch.setattr(server, "ROOT", tmp_path)


def freeze_today(monkeypatch, year, month, day):
    class FrozenDate(_real_date):
        @classmethod
        def today(cls):
            return cls(year, month, day)

    monkeypatch.setattr(server, "date", FrozenDate)


@pytest.fixture
def amsterdam(monkeypatch):
    """Run the test in Europe/Amsterdam, where local midnight is 22:00Z in summer."""
    monkeypatch.setenv("TZ", "Europe/Amsterdam")
    _time.tzset()
    yield
    monkeypatch.undo()
    _time.tzset()


def write_sessions(tmp_path, walks):
    (tmp_path / "sessions.json").write_text(json.dumps(walks))


def walk(started, ended, meters=1000, seconds=1200, steps=1601, kcal=60.0):
    return dict(id=started, startedAt=started, endedAt=ended, distanceM=meters,
                activeDurationS=seconds, steps=steps, caloriesKcal=kcal,
                exportedToHealth=False)


def test_a_walk_after_local_midnight_belongs_to_the_local_day(tmp_path, monkeypatch, amsterdam):
    point_at(tmp_path, monkeypatch)
    freeze_today(monkeypatch, 2026, 7, 13)
    write_sessions(tmp_path, [
        # 21:30 local on the 12th, 00:30 local on the 13th, 23:30 local on the 13th
        walk("2026-07-12T19:30:00Z", "2026-07-12T19:50:00Z", meters=111),
        walk("2026-07-12T22:30:00Z", "2026-07-12T22:50:00Z", meters=222),
        walk("2026-07-13T21:30:00Z", "2026-07-13T21:40:00Z", meters=333, seconds=600),
    ])
    today = server._today()
    assert today["d"] == "2026-07-13"
    # 222 (00:30 local, on UTC's 12th) and 333 (23:30 local); not 111.
    assert today["m"] == 222 + 333


def test_row_day_is_the_local_day(tmp_path, monkeypatch, amsterdam):
    point_at(tmp_path, monkeypatch)
    write_sessions(tmp_path, [walk("2026-07-12T22:30:00Z", "2026-07-12T22:50:00Z")])
    assert server._row(server._sessions()[0])["d"] == "2026-07-13"


def test_a_walk_across_local_midnight_is_split_like_the_app_splits_it(tmp_path, monkeypatch, amsterdam):
    point_at(tmp_path, monkeypatch)
    # 23:50 to 00:10 local, 20 minutes, 1000 m, 1601 steps (same numbers as the app's test)
    write_sessions(tmp_path, [walk("2026-07-13T21:50:00Z", "2026-07-13T22:10:00Z")])
    freeze_today(monkeypatch, 2026, 7, 13)
    first = server._today()
    freeze_today(monkeypatch, 2026, 7, 14)
    second = server._today()
    assert (first["s"], second["s"]) == (600, 600)
    assert first["m"] + second["m"] == 1000
    assert first["steps"] + second["steps"] == 1601
    assert round(first["kcal"] + second["kcal"], 1) == 60.0


def test_a_live_run_never_replaces_the_days_total(tmp_path, monkeypatch):
    """Old rule: live.m >= today.m replaced the total with the live run."""
    point_at(tmp_path, monkeypatch)
    now = datetime.now().astimezone()
    start = now.replace(hour=12, minute=0, second=0, microsecond=0)
    write_sessions(tmp_path, [walk(start.isoformat(), (start + timedelta(minutes=20)).isoformat(),
                                   meters=3000, seconds=1200, steps=4000, kcal=100.0)])
    # The compact shape older builds wrote: the open run only, bigger than the day so far.
    (tmp_path / "live.json").write_text(json.dumps(
        dict(t=datetime.now(timezone.utc).timestamp(), on=True, kmh=3.2, m=5000, s=3000, steps=7000, kcal=200.0)))
    today = server._today()
    assert today["m"] == 3000 and today["steps"] == 4000
    assert server._live()["m"] == 5000  # the live run is still readable on its own


def test_the_apps_day_total_wins_when_it_is_fresh(tmp_path, monkeypatch):
    point_at(tmp_path, monkeypatch)
    now = datetime.now().astimezone()
    start = now.replace(hour=12, minute=0, second=0, microsecond=0)
    write_sessions(tmp_path, [walk(start.isoformat(), (start + timedelta(minutes=20)).isoformat(), meters=3000)])
    data = snapshot(tmp_path, monkeypatch, distanceM=5000, todayDistanceM=8000, todayMinutes=70)
    write_sessions(tmp_path, [walk(start.isoformat(), (start + timedelta(minutes=20)).isoformat(), meters=3000)])
    today = server._today()
    assert today["m"] == 8000  # finished walk + open run, as the app counts them
    assert today["s"] == 70 * 60
    assert data["distanceM"] == 5000


def test_totals_labelled_with_yesterday_are_not_todays(tmp_path, monkeypatch):
    """Just after midnight the app can still publish yesterday's totals in a fresh file."""
    point_at(tmp_path, monkeypatch)
    yesterday = (datetime.now().astimezone() - timedelta(days=1)).date().isoformat()
    snapshot(tmp_path, monkeypatch, todayDate=yesterday, todayDistanceM=8000)
    assert server._today()["m"] == 0


def test_folder_that_appears_later_is_found(tmp_path, monkeypatch):
    """The audited server fixed its folder when the module was imported."""
    later = tmp_path / "created-after-import"
    monkeypatch.setenv("Z1_SESSIONS_DIR", str(later))
    if hasattr(server, "ROOT"):
        monkeypatch.setattr(server, "ROOT", later)
    assert server._sessions() == []
    later.mkdir()
    (later / "sessions.json").write_text(json.dumps([walk("2026-07-13T09:00:00Z", "2026-07-13T09:20:00Z")]))
    if hasattr(server, "ROOT"):
        pytest.skip("audited server cannot see it")
    assert len(server._sessions()) == 1


def test_garbage_numbers_do_not_crash_the_tool(tmp_path, monkeypatch):
    point_at(tmp_path, monkeypatch)
    write_sessions(tmp_path, [dict(startedAt="2026-07-13T09:00:00Z", distanceM="far", activeDurationS=None, steps=[], caloriesKcal="x")])
    assert server._row(server._sessions()[0])["m"] == 0
    freeze_today(monkeypatch, 2026, 7, 13)
    assert server._today()["m"] == 0


def test_server_exposes_exactly_one_read_only_tool():
    """Skipped where the MCP SDK is not installed; the data functions above do not need it."""
    pytest.importorskip("mcp")
    import asyncio

    tools = asyncio.run(server.build_server().list_tools())
    assert [tool.name for tool in tools] == ["z1"]
