# Cloud work on Z1 WalkingPad

Cloud agents receive a GitHub checkout in Linux. Read `CLAUDE.md` first. They can inspect/edit code, write docs and tests, and run Python pytest after installing dependencies. They cannot build or run the SwiftUI/AppKit/Bluetooth app or test a real pad or iPhone. GitHub Actions performs the native build, fake-transport checks, and Python tests on macOS. Hardware and phone acceptance still need local checks.

## Claude Code on the web

1. Open [Claude Code](https://claude.ai/code) and connect GitHub. Select the public `fortun8te/z1-walkingpad` repo and `final-polish` branch.
2. Start a cloud session with a focused task. The agent should read `CLAUDE.md`; for Python work it can run `python3 -m pip install '.[dev]'` and `python3 -m pytest -q`.
3. Review the diff, create a branch/PR from the session, and check the macOS Verify job on the PR.

## Codex cloud

1. In [Codex](https://chatgpt.com/codex), choose **Work in → Cloud**. Connect GitHub if prompted, create or select an environment containing `fortun8te/z1-walkingpad`, and publish it after setup review.
2. Start a task for `final-polish`. Ask for a focused change and a PR. Review the changed files and test report before opening or updating the PR.

## GitHub verification

Open a PR against the intended base branch. `.github/workflows/verify.yml` runs `swift build` and `swift run z1tests` from `macos/`, plus Python pytest, on `macos-15`. Review its result in the PR's **Checks** tab. A green check is automated evidence, not proof of a real belt Stop or Health delivery. Never include secrets or personal data in the repo or PR.

Pushing workflow files requires the GitHub token's `workflow` scope; Michael runs `gh auth refresh -s workflow` once.
