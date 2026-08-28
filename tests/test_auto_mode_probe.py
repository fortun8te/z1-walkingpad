import importlib.util
import sys
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "auto_mode_probe", Path(__file__).parents[1] / "scripts" / "auto_mode_probe.py"
)
assert _SPEC and _SPEC.loader
auto_mode_probe = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = auto_mode_probe
_SPEC.loader.exec_module(auto_mode_probe)
decode_mode = auto_mode_probe.decode_mode
idle_gate_passed = auto_mode_probe.idle_gate_passed
mode_value_for_auto = auto_mode_probe.mode_value_for_auto


def test_decode_mode_uses_bits_5_to_7_and_preserves_unknown_values():
    assert decode_mode(0x0000) == (0, "manual")
    assert decode_mode(0x0021) == (1, "auto")
    assert decode_mode(0x0040) == (2, "sleep")
    assert decode_mode(0x00E0) == (7, "unknown (7)")
    assert decode_mode(None) == (None, "not reported")


def test_auto_candidate_preserves_unrelated_property_bits():
    assert mode_value_for_auto(0x8013) == 0x8033


def test_idle_gate_requires_explicit_stopped_status():
    assert idle_gate_passed([], 0x02, False)
    assert not idle_gate_passed([], None, False)
    assert not idle_gate_passed([0.1], 0x02, False)
    assert not idle_gate_passed([], 0x02, True)


def test_probe_module_does_not_offer_a_write_mode_flag():
    # The current hardware probe is intentionally read-only.  A future
    # experiment must add a separate, reviewed motion gate before writing.
    import inspect

    source = inspect.getsource(auto_mode_probe)
    assert "property_write_frame" not in source
    assert "CHAR_CONTROL_POINT" not in source
