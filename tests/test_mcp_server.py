"""Current read-only MCP contract. All session reads use temporary fixtures."""
import importlib
import os
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import subprocess
import sys

from z1_walkingpad_mcp import server


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
