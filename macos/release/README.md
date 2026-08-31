# Release server

Local update feed for Z1 WalkingPad. The app checks
`http://127.0.0.1:8741/latest.json` and shows **Update available** when the
feed build is newer. Install quits (belt keeps moving), swaps
`/Applications/Z1WalkingPad.app` in place, and reopens.

```bash
# terminal 1 — leave running
bash macos/release/serve.sh

# terminal 2 — each time you want to ship
Z1_RELEASE_NOTES="steps match the pad" bash macos/release/publish.sh
```

Then open the popover and click **Install**.
