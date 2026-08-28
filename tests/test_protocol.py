"""Unit tests for the vendor/FTMS frame builders and parsers (no BLE needed)."""

from z1_walkingpad_mcp import protocol as p


def test_unlock_frame_z1d():
    # Verified on hardware 2026-07-30: KS-HD-Z1D answered 71 80 to this exact frame.
    assert p.unlock_frame("KS-HD-Z1D") == bytes.fromhex("71 00 05 01 2e 5a 31 44 74".replace(" ", ""))


def test_unlock_frame_too_short():
    import pytest

    with pytest.raises(ValueError):
        p.unlock_frame("abc")


def test_build_frame_checksum():
    frame = p.build_frame(0x72, 0x00, b"\x00")
    assert frame == bytes([0x72, 0x00, 0x01, 0x00, 0x73])


def test_parse_frame_roundtrip():
    raw = p.build_frame(0x71, 0x81, b"\x03\x00\x00\x00")
    assert p.parse_frame(raw) == (0x71, 0x81, b"\x03\x00\x00\x00")


def test_parse_frame_bad_checksum():
    raw = bytearray(p.build_frame(0x72, 0x80, b"\x01\x02"))
    raw[-1] ^= 0xFF
    assert p.parse_frame(bytes(raw)) is None


def test_parse_frame_truncated():
    assert p.parse_frame(b"\x71\x80") is None
    assert p.parse_frame(b"\x71\x80\x05\x01") is None


def test_is_unlock_ok():
    raw = p.build_frame(0x71, 0x80, b"")
    assert p.is_unlock_ok(raw)
    assert not p.is_unlock_ok(p.build_frame(0x71, 0x81, b""))


def test_parse_property_records():
    # 4-byte records [id, err, lo, hi]; records with err != 0 skipped
    data = bytes([1, 0, 3, 0, 5, 1, 9, 9, 6, 0, 0, 0])
    assert p.parse_property_records(data) == {1: 3, 6: 0}


def test_parse_treadmill_data_real_frame():
    # Captured from the pad: flags 0x2404 (distance, elapsed time, steps), speed 2.5 km/h
    raw = bytes.fromhex("0424fa0000000002000000".replace(" ", ""))
    d = p.parse_treadmill_data(raw)
    assert d.speed_kmh == 2.5
    assert d.distance_m == 0
    assert d.elapsed_s == 2
    assert d.steps == 0


def test_parse_treadmill_data_more_data_bit():
    # flags bit0 set -> no instantaneous speed field
    raw = bytes.fromhex("0524" + "000000" + "3c00" + "e803")
    d = p.parse_treadmill_data(raw)
    assert d.speed_kmh is None
    assert d.distance_m == 0
    assert d.elapsed_s == 60
    assert d.steps == 1000


def test_sysinfo_frame_layout():
    frame = p.sysinfo_frame(0x6A6AD4E1)
    assert frame[:3] == bytes([0x71, 0x01, 0x08])
    assert frame[3:7] == (0x6A6AD4E1).to_bytes(4, "little")
    assert frame[7:11] == b"\x00\x00\x00\x00"
    assert frame[-1] == sum(frame[:-1]) & 0xFF


def test_parse_treadmill_data_truncated_frame_dropped_whole():
    # Flags claim distance+elapsed+steps, but the frame is cut short after
    # speed: the missing tail must not decode as zeros (which read as a
    # counter reset and would wipe calories/steps downstream).
    raw = bytes.fromhex("0424fa00")  # speed present; flagged fields absent
    d = p.parse_treadmill_data(raw)
    assert d.speed_kmh == 2.5
    assert d.distance_m is None
    assert d.elapsed_s is None
    assert d.steps is None
