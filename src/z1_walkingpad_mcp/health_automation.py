"""Optional macOS Shortcut trigger for the iPhone Health automation."""

from __future__ import annotations

import os
import shutil
import subprocess

ENV_NAME = "Z1_HEALTH_TRIGGER_SHORTCUT"


def trigger_health_shortcut() -> str | None:
    """Launch the configured macOS Shortcut without blocking treadmill stop.

    The shortcut should toggle a shared Focus.  The matching iPhone personal
    automation then runs the Health importer after iCloud has synced the file.
    """
    name = os.environ.get(ENV_NAME, "").strip()
    if not name:
        return None
    executable = shutil.which("shortcuts")
    if executable is None:
        return "macOS shortcuts command is unavailable"
    try:
        subprocess.Popen(
            [executable, "run", name],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        return f"could not start Health automation: {exc}"
    return "launched"
