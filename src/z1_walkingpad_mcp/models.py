from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class GovernorState(str, Enum):
    DISCONNECTED = "disconnected"
    READY = "ready"
    STARTING = "starting"
    RAMPING = "ramping"
    RUNNING = "running"
    PAUSED = "paused"
    FAULTED = "faulted"
    STOPPING = "stopping"


class FaultCode(str, Enum):
    NONE = "none"
    STALE_TELEMETRY = "stale_telemetry"
    BLE_LOST = "ble_lost"
    COMMAND_TIMEOUT = "command_timeout"
    STEP_OFF = "step_off"


class StepSource(str, Enum):
    RAW = "raw"
    ESTIMATED = "estimated"
    CALIBRATED = "calibrated"
    UNKNOWN = "unknown"


@dataclass
class TelemetrySample:
    ts: float
    speed_kmh: float | None
    distance_m: float | None
    elapsed_s: float | None
    steps: int | None


@dataclass
class GovernorStatus:
    state: GovernorState
    fault: FaultCode = field(default=FaultCode.NONE)
    target_speed_kmh: float | None = None
    current_speed_kmh: float | None = None
    distance_m: float | None = None
    elapsed_s: float | None = None
    steps: int | None = None
    step_source: StepSource = StepSource.UNKNOWN
    session_id: str | None = None
    message: str = ""

    def to_dict(self) -> dict:
        return {
            "state": self.state.value,
            "fault": self.fault.value,
            "target_speed_kmh": self.target_speed_kmh,
            "current_speed_kmh": self.current_speed_kmh,
            "distance_m": self.distance_m,
            "elapsed_s": self.elapsed_s,
            "steps": self.steps,
            "step_source": self.step_source.value,
            "session_id": self.session_id,
            "message": self.message,
        }
