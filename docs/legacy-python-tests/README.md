# Retired Python control tests

These eleven test files are preserved unchanged from the prior Python BLE/control implementation. That implementation was already removed by the native-app rebuild before this review. They import deleted modules and cannot test the current read-only MCP package.

The active tests remain under `tests/`: vendor protocol parsing, the read-only auto-mode probe helpers, and the current MCP contract. Native control, session recording, grouping, and metrics are tested by the Swift `z1tests` runner.

The pytest configuration limits default collection to `tests/`. It also excludes `scripts/`, where historical hardware experiments execute Bluetooth actions at import time. Do not import or run those scripts as tests.

These archived tests are reference material, not skipped active coverage. Restore or port them only alongside a supported implementation.
