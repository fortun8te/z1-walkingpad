from __future__ import annotations

import json
import os
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


def _utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")


def _atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class SessionRecorder:
    def __init__(self, sessions_dir: Path) -> None:
        self.sessions_dir = Path(sessions_dir)
        self.session_id: str | None = None
        self._started_at: float | None = None
        self._last_session_id: str | None = None

    @property
    def journal_path(self) -> Path:
        sid = self.session_id or self._last_session_id
        assert sid is not None, "no session started"
        return self.sessions_dir / f"{sid}.journal.jsonl"

    def start(self, meta: dict | None = None) -> str:
        self.session_id = f"{_utc_stamp()}-{uuid.uuid4().hex[:6]}"
        self._last_session_id = self.session_id
        self._started_at = time.time()
        self.sessions_dir.mkdir(parents=True, exist_ok=True)
        record = {"kind": "start", "ts": self._started_at}
        if meta:
            record.update(meta)
        with self.journal_path.open("a") as f:
            f.write(json.dumps(record) + "\n")
            f.flush()
            os.fsync(f.fileno())
        return self.session_id

    def log(self, kind: str, payload: dict | None = None, *, _fsync: bool = True) -> None:
        if self.session_id is None:
            return
        record = {"kind": kind, "ts": time.time()}
        if payload:
            record.update(payload)
        with self.journal_path.open("a") as f:
            f.write(json.dumps(record) + "\n")
            if _fsync:
                f.flush()
                try:
                    os.fsync(f.fileno())
                except OSError:
                    pass

    def log_telemetry(self, sample: dict) -> None:
        # perf: telemetry is 1Hz, no need to fsync each sample — fsync only on important events
        self.log("telemetry", sample, _fsync=False)

    def finalize(self, outcome: str = "completed", summary: dict | None = None) -> Path:
        assert self.session_id is not None
        ended_at = time.time()
        end_record = {"kind": "end", "outcome": outcome, "ts": ended_at}
        if summary:
            end_record.update(summary)
        with self.journal_path.open("a") as f:
            f.write(json.dumps(end_record) + "\n")
            f.flush()
            os.fsync(f.fileno())
        sid_for_path = self.session_id
        started_at = self._started_at
        self.session_id = None
        self._started_at = None
        ready = {
            "session_id": sid_for_path,
            "outcome": outcome,
            "started_at": started_at,
            "ended_at": ended_at,
        }
        if summary:
            ready.update(summary)
        path = self.sessions_dir / f"session-{sid_for_path}.json"
        _atomic_write_json(path, ready)
        # keep agent-data.json fresh for agents (no extra I/O if no sessions)
        try:
            from .highscores import write_agent_export
            write_agent_export(self.sessions_dir)
        except Exception:
            pass
        return path


def recover_incomplete(sessions_dir: Path) -> list[Path]:
    recovered: list[Path] = []
    sessions_dir = Path(sessions_dir)
    if not sessions_dir.exists():
        return recovered
    for journal in sorted(sessions_dir.glob("*.journal.jsonl")):
        session_id = journal.name[: -len(".journal.jsonl")]
        ready = sessions_dir / f"session-{session_id}.json"
        if ready.exists():
            continue
        ts = time.time()
        with journal.open("a") as f:
            f.write(json.dumps({"kind": "recovery", "outcome": "incomplete", "ts": ts}) + "\n")
            f.flush()
            os.fsync(f.fileno())
        _atomic_write_json(ready, {"session_id": session_id, "outcome": "incomplete-recovered"})
        recovered.append(ready)
    return recovered
