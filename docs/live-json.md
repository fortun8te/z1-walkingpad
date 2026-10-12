# live.json

The Mac app publishes one small file for other local readers (Superapp, the
read-only MCP in `src/`). It never carries commands: nothing can start, stop or
speed up the belt through it.

`~/Library/Application Support/Z1 WalkingPad/live.json`

```json
{
  "schema": 1,
  "updatedAt": "2026-10-12T19:30:05Z",
  "connected": true,
  "beltRunning": true,
  "speedKmh": 3.2,
  "elapsedSec": 300, "distanceM": 267, "steps": 418, "caloriesKcal": 19.25,
  "todayDate": "2026-10-12",
  "todayDistanceM": 1600, "todayMinutes": 30.0, "todaySteps": 2400, "todayKcal": 87.5,
  "goalProgress": 0.25
}
```

- `elapsedSec`, `distanceM`, `steps`, `caloriesKcal` belong to the walk the pad is
  counting now. They fall to the pad's next walk when it resets.
- `today*` is the whole local day: finished walks plus the walk in progress.
  `todayDate` names the local day those totals belong to. Just after midnight
  the app can still publish yesterday's totals for a minute or two, so a reader
  must compare `todayDate` with its own idea of today and not trust
  `updatedAt` for that.
- `connected: false` clears the live fields; the day totals stay.

## When it is written

Writes are atomic (temp file and rename), so a reader never sees half a file.

| Change | Written |
| --- | --- |
| connected, belt started or stopped, a new local day | at once |
| anything while nothing is streaming (disconnected, or connected with the belt idle): a finished walk, a new goal | at once |
| speed changed (to 0.1 km/h), belt moving | at most once a second |
| plain progress (clock, distance, steps), belt moving | every 5 s |
| an identical snapshot, or an identical one while idle | never |

The pad stops streaming when the belt stops, so after a Stop no later frame
would correct the file. That is why a state change is never held back.

## What a reader should assume

- Treat the file as live while `updatedAt` is younger than 15 s (a walk widget)
  or 90 s (a script). While the belt moves it is refreshed at least every 5 s.
- A connected, idle pad does not refresh the file. Old `updatedAt` with
  `beltRunning: false` is normal, not a fault.
- Watch the folder, do not poll: the rename is the event.
- `updatedAt` comes from the Mac's clock. If the clock is set back, the next
  frame is written immediately, so a reader can see `updatedAt` go backwards
  once.
