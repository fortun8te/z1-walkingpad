from z1_walkingpad_mcp.session_clock import SessionClock


def test_ten_minute_break_stays_one_session_but_is_not_active_time():
    clock = SessionClock()
    clock.start(wall_time=1_000, monotonic_time=0)
    clock.pause(monotonic_time=600)
    clock.start(wall_time=1_600, monotonic_time=1_200)
    clock.pause(monotonic_time=1_800)

    snapshot = clock.snapshot(monotonic_time=1_800)
    assert snapshot["started_at"] == 1_000
    assert snapshot["active_duration_s"] == 1_200


def test_duplicate_start_and_pause_are_idempotent():
    clock = SessionClock()
    clock.start(wall_time=1_000, monotonic_time=10)
    clock.start(wall_time=1_001, monotonic_time=20)
    clock.pause(monotonic_time=40)
    clock.pause(monotonic_time=50)

    assert clock.snapshot(monotonic_time=60) == {
        "started_at": 1_000,
        "active_duration_s": 30.0,
    }


def test_mid_session_connection_recovers_elapsed_start():
    clock = SessionClock()
    clock.seed_running_elapsed(600, wall_time=2_000, monotonic_time=50)
    clock.pause(monotonic_time=350)

    assert clock.snapshot(monotonic_time=350) == {
        "started_at": 1_400,
        "active_duration_s": 900.0,
    }
