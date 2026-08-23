import json

from z1_walkingpad_mcp.session_recorder import SessionRecorder, recover_incomplete


def test_full_lifecycle(tmp_path):
    rec = SessionRecorder(tmp_path)
    sid = rec.start({"device": "z1"})
    rec.log("command", {"op": "start"})
    rec.log_telemetry({"speed_kmh": 2.0})
    path = rec.finalize("completed", {"distance_m": 42})
    data = json.loads(path.read_text())
    assert data["session_id"] == sid
    assert data["outcome"] == "completed"
    assert data["distance_m"] == 42
    lines = [json.loads(x) for x in rec.journal_path.read_text().splitlines()]
    assert lines[0]["kind"] == "start" and lines[-1]["kind"] == "end"


def test_crash_recovery_once(tmp_path):
    rec = SessionRecorder(tmp_path)
    rec.start()
    rec.log_telemetry({"speed_kmh": 1.0})
    first = recover_incomplete(tmp_path)
    second = recover_incomplete(tmp_path)
    assert len(first) == 1 and second == []
    data = json.loads(first[0].read_text())
    assert data["outcome"] == "incomplete-recovered"
