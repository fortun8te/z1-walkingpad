"""Exercise packaging failures without signing or reading Health data."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest


@pytest.mark.parametrize("outcome", ["failure", "empty", "success"])
def test_signing_only_replaces_last_working_shortcut_after_success(tmp_path, outcome):
    root = Path(__file__).resolve().parents[1]
    scripts = tmp_path / "scripts"
    shortcuts = tmp_path / "shortcuts"
    binaries = tmp_path / "bin"
    for directory in (scripts, shortcuts, binaries):
        directory.mkdir()
    shutil.copy2(root / "scripts/build_health_shortcut.sh", scripts)
    shutil.copy2(root / "shortcuts/Z1 Import Health.xml", shortcuts)
    destination = shortcuts / "Z1 Import Health v3.1.shortcut"
    destination.write_bytes(b"previous working artifact")

    # Model the tools' file behavior, including a signer that writes partial
    # output before returning an error. No Apple service or signing runs.
    plutil = binaries / "plutil"
    plutil.write_text('#!/bin/sh\nif [ "$1" = "-convert" ]; then printf unsigned > "$4"; fi\n')
    signer = binaries / "shortcuts"
    signer.write_text(
        '#!/bin/sh\nwhile [ "$1" != "--output" ]; do shift; done\nshift\n'
        'case "$SIGN_OUTCOME" in\n'
        'failure) printf partial > "$1"; exit 1;;\n'
        'empty) : > "$1";;\n'
        'success) printf "new signed artifact" > "$1";;\nesac\n'
    )
    plutil.chmod(0o755)
    signer.chmod(0o755)
    environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", SIGN_OUTCOME=outcome)
    result = subprocess.run(["sh", str(scripts / "build_health_shortcut.sh")],
                            env=environment, capture_output=True, text=True, check=False)
    if outcome == "success":
        assert result.returncode == 0, result.stderr
        assert destination.read_bytes() == b"new signed artifact"
        assert result.stdout.strip() == str(destination)
    else:
        assert result.returncode != 0
        assert destination.read_bytes() == b"previous working artifact"
