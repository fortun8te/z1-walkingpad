# Apple Health bridge

HealthKit does not allow data writes on macOS ([Apple docs](https://developer.apple.com/documentation/healthkit/hkhealthstore/ishealthdataavailable()):
the framework ships on macOS 13+, but `isHealthDataAvailable()` returns
`false` there). So sessions recorded on the Mac reach Apple Health through
the iPhone, via iCloud Drive + a Shortcut. No third-party apps or services.

## 1. Point the session log at iCloud Drive (Mac, one time)

```bash
# in ~/.zprofile or wherever you set environment for the MCP server:
export Z1_SESSIONS_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/z1-walkingpad"
```

If the MCP server is configured in a client (Claude/Kimi/etc.), set it in the
server's env config instead:

```json
{
  "mcpServers": {
    "z1-walkingpad": {
      "command": "/path/to/z1-walkingpad-mcp/.venv/bin/python",
      "args": ["-m", "z1_walkingpad_mcp.server"],
      "env": {
        "Z1_WEIGHT_KG": "80",
        "Z1_SESSIONS_DIR": "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/z1-walkingpad"
      }
    }
  }
}
```

From then on, every `treadmill_stop` writes a `session-<timestamp>.json`
into that folder, and iCloud syncs it to the iPhone. File contents:

```json
{
  "ended_at": 1785369234,
  "duration_s": 1530,
  "distance_m": 1020,
  "steps": 2104,
  "avg_speed_kmh": 2.4,
  "calories_kcal": 92.5,
  "weight_kg_used": 80.0
}
```

## 2. Build the Shortcut (iPhone, one time)

In **Shortcuts → +**, add these actions:

1. **Get Contents of Folder** — Folder: `iCloud Drive/z1-walkingpad` (tap the
   folder variable → Service: iCloud Drive, pick the folder)
2. **Filter Files** — where `Name` `begins with` `session-`
3. **Repeat with Each** over the filtered files:
   - **Get Text from** [Repeat Item]
   - **Get Dictionary from Input** (Text → Dictionary)
   - **Get Dictionary Value** `ended_at` → save as variable `End`
   - **Get Dictionary Value** `duration_s` → variable `Dur`
   - **Adjust Date** — subtract `Dur` seconds from `End` → variable `Start`
   - **Log Workout** — Type: `Walking`, Start: `Start`, End: `End`,
     Calories: dictionary value `calories_kcal`,
     Distance: dictionary value `distance_m` (unit: m)
   - *(optional)* **Log Health Sample** — Type: `Steps`, Value: dictionary
     value `steps`, Date: `End`
   - **Delete File** [Repeat Item] *(so each session is logged exactly once —
     files are the queue)*

Run it manually after a walk, or add an **Automation** (e.g. time-of-day
evening) that runs it daily.

## Notes

- The Shortcut marks the workout as Walking with the pad's distance and our
  MET-based calorie estimate; watch/phone sensors will still win for heart
  rate if you wear a watch — the Z1 has none.
- `sessions.jsonl` (the append-only full history) stays in the same folder
  and is ignored by the Shortcut (`session-` prefix filter).
- If iCloud sync is slow, the files queue up harmlessly — the Shortcut
  processes whatever has arrived.
