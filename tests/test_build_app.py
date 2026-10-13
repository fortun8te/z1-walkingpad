"""Exercise bundle publication without compiling, signing, or launching an app."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest


@pytest.fixture
def bundle_build(tmp_path):
    project = tmp_path / "project with spaces"
    project.mkdir()
    script = project / "build-app.sh"
    shutil.copyfile(Path(__file__).parents[1] / "macos/build-app.sh", script)
    resources = project / "Resources"
    resources.mkdir()
    (resources / "AppIcon.icns").write_bytes(b"icon")
    binary_dir = tmp_path / "compiled binary"
    binary_dir.mkdir()
    (binary_dir / "Z1App").write_bytes(b"new executable")
    commands = tmp_path / "commands"
    commands.mkdir()
    shims = {
        "swift": '#!/bin/bash\nif [[ "$*" == *--show-bin-path* ]]; then echo "$TEST_BIN"; fi\n',
        "xcodebuild": "#!/bin/sh\nexit 0\n",
        "xattr": "#!/bin/sh\nexit 0\n",
        "codesign": '''#!/bin/bash
if [[ "$1" == "--verify" && "${TEST_FAIL_VERIFY:-0}" == "1" ]]; then exit 1; fi
if [[ "$1" == "-d" ]]; then echo 'Identifier=dev.z1walkingpad.menubar'; fi
exit 0
''',
        "mv": '''#!/bin/bash
if [[ "${TEST_FAIL_PUBLISH:-0}" == "1" && "$1" == */.z1-bundle.*/Z1WalkingPad.app ]]; then exit 1; fi
exec /bin/mv "$@"
''',
    }
    for name, text in shims.items():
        path = commands / name
        path.write_text(text)
        path.chmod(0o755)
    output = tmp_path / "bundle output"
    output.mkdir()
    existing = output / "Z1WalkingPad.app"
    existing.mkdir()
    (existing / "previous").write_bytes(b"last verified build")
    (output / "unrelated").write_bytes(b"keep")
    env = {
        **os.environ,
        "PATH": f"{commands}:/usr/bin:/bin",
        "TEST_BIN": str(binary_dir),
        "Z1_BUILD_DIST": str(output),
    }

    def run(**overrides):
        return subprocess.run(
            ["/bin/bash", str(script), "--quiet"],
            env={**env, **overrides}, capture_output=True, text=True, check=False,
        )

    return output, run


@pytest.mark.parametrize("failure", ["TEST_FAIL_VERIFY", "TEST_FAIL_PUBLISH"])
def test_failed_bundle_keeps_previous_verified_build(bundle_build, failure):
    output, run = bundle_build
    result = run(**{failure: "1"})
    assert result.returncode != 0
    assert (output / "Z1WalkingPad.app/previous").read_bytes() == b"last verified build"
    assert (output / "unrelated").read_bytes() == b"keep"
    assert not list(output.glob(".z1-bundle.*"))


def test_verified_bundle_replaces_previous_only_after_success(bundle_build):
    output, run = bundle_build
    result = run()
    assert result.returncode == 0, result.stderr
    app = output / "Z1WalkingPad.app"
    assert (app / "Contents/MacOS/Z1WalkingPad").read_bytes() == b"new executable"
    assert not (app / "previous").exists()
    assert (output / "unrelated").read_bytes() == b"keep"
    assert not list(output.glob(".z1-bundle.*"))


def test_replacing_bundle_symlink_leaves_target_untouched(bundle_build, tmp_path):
    output, run = bundle_build
    app = output / "Z1WalkingPad.app"
    previous_target = tmp_path / "previous target"
    app.rename(previous_target)
    app.symlink_to(previous_target, target_is_directory=True)
    result = run()
    assert result.returncode == 0, result.stderr
    assert not app.is_symlink()
    assert (previous_target / "previous").read_bytes() == b"last verified build"
