"""Pause-aware wall and active timing for one treadmill workout."""

from __future__ import annotations

import time


class SessionClock:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.started_at: float | None = None
        self._active_s = 0.0
        self._active_since: float | None = None

    @property
    def running(self) -> bool:
        return self._active_since is not None

    def start(self, wall_time: float | None = None, monotonic_time: float | None = None) -> None:
        wall = time.time() if wall_time is None else wall_time
        mono = time.monotonic() if monotonic_time is None else monotonic_time
        if self.started_at is None:
            self.started_at = wall
        if self._active_since is None:
            self._active_since = mono

    def seed_running_elapsed(
        self,
        elapsed_s: float,
        wall_time: float | None = None,
        monotonic_time: float | None = None,
    ) -> None:
        """Recover a session first observed after the belt was already moving."""
        if self.started_at is not None:
            self.start(wall_time=wall_time, monotonic_time=monotonic_time)
            return
        wall = time.time() if wall_time is None else wall_time
        mono = time.monotonic() if monotonic_time is None else monotonic_time
        elapsed = max(0.0, elapsed_s)
        self.started_at = wall - elapsed
        self._active_s = elapsed
        self._active_since = mono

    def pause(self, monotonic_time: float | None = None) -> None:
        if self._active_since is None:
            return
        mono = time.monotonic() if monotonic_time is None else monotonic_time
        self._active_s += max(0.0, mono - self._active_since)
        self._active_since = None

    def snapshot(self, monotonic_time: float | None = None) -> dict:
        active = self._active_s
        if self._active_since is not None:
            mono = time.monotonic() if monotonic_time is None else monotonic_time
            active += max(0.0, mono - self._active_since)
        return {"started_at": self.started_at, "active_duration_s": active}
