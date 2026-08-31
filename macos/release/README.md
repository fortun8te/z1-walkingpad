# Release server

Local update feed for Z1 WalkingPad. The app checks
`http://127.0.0.1:8741/latest.json` and shows **Update available** when the
feed build is newer. Install quits (belt keeps moving), swaps
`/Applications/Z1WalkingPad.app` in place, and reopens.

The menu-bar app starts `http://127.0.0.1:8741` itself while it is running.
You only need to publish:

```bash
Z1_RELEASE_NOTES="steps match the pad" bash macos/release/publish.sh
```

`serve.sh` is optional (for when the app is quit). Auto-update installs when the feed build is newer.
