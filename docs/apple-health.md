# Apple Health

HealthKit itself does not run on macOS. Apple's own DTS said so in 2025:
`HKHealthStore.isHealthDataAvailable()` is false, and Mac apps cannot read
the Health database. iOS apps (Strava, WHOOP, Metric, scale apps) talk to
HealthKit on the phone. Mac apps that show Health data import an
`export.xml`, or they get a file from an iPhone Shortcut.

This project uses the Shortcut route, same folder as the workout queue.

## Latest weight → calories

1. On the iPhone, make a Shortcut:

   - Find Health Samples → Type is Weight → Sort by Start Date, latest first, Limit 1
   - Get Details of Health Sample → Value (kg)
   - Get Details of Health Sample → Start Date
   - Text:

     ```json
     {"kg": VALUE, "measuredAt": DATE, "source": "apple-health"}
     ```

     (Shortcuts can substitute the value and an ISO date.)
   - Save File → `Shortcuts/z1-walkingpad/weight.json`, overwrite.

2. Automation: Time of Day each morning, or App → Health / your scale app → Is Opened.

3. In the Mac app: Settings → **Use latest Apple Health weight**. The menu bar
   app reads that file on launch and every 15 minutes and uses it for ACSM kcal.

The file on the Mac is:

`~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/z1-walkingpad/weight.json`

# Apple Health → WHOOP

The Mac now places finished WalkingPad workouts in iCloud Drive automatically.
The included iPhone Shortcut logs each one as a Walking workout in Apple Health,
then deletes the queue file. WHOOP supplies heart rate, calories, and Strain
from the band you are already wearing.

## Easy setup

1. Open [`shortcuts/Z1 Import Health v3.1.shortcut`](../shortcuts/Z1%20Import%20Health%20v3.1.shortcut)
   and choose **Add Shortcut**. It will sync to the iPhone through iCloud.
   Delete any older copy — v1 and v2 could not read the queue at all.
2. On the iPhone, run **Z1 Import Health** once. Approve Files, Health, and
   deleting files if asked. It is safe if the queue is empty.
3. In **Shortcuts → Automation → + → App**, choose **WHOOP**, select
   **Is Opened**, run **Z1 Import Health**, and choose **Run Immediately**.

That is all. No Focus, Strava, folder picker, or environment variables are
needed. Opening WHOOP imports any finished walks waiting in iCloud.

If iCloud Shortcuts sync is off, enable it in iPhone Settings → Apple Account →
iCloud → See All → Shortcuts.

## Workout behaviour

- A session must contain at least 10 active minutes and 100 metres before it is
  offered to Health. This avoids tiny fragments becoming separate workouts.
- **Pause**, then resume, keeps a break inside one workout. **Stop** finishes it.
- Apple Health receives the real start time, wall-clock duration, and belt
  distance.
- **Shortcut v3.1 also logs a step sample spanning the walk window.** Be aware
  of the overlap: if your iPhone was on you while you walked, it counted those
  steps too, and Health will hold both sources for the same minutes. The pad's
  counter is also unvalidated — see "Your stride" in `../macos/README.md`.
- The bridge sends **no calorie sample** — WHOOP computes calories and Strain
  from the band's own heart rate and ignores anything we send.
- The menu-bar app connects automatically and watches the Z1 without starting
  or changing it. A physical-remote Start begins/resumes tracking. A physical-
  remote Stop starts a 10-minute grace period; restarting inside it keeps one
  workout, while staying stopped exports automatically. The standalone CLI does
  not currently export to Health.

## Where the queue lives (and why it matters)

The queue is **one file**:

`iCloud Drive/Shortcuts/z1-walkingpad/health-queue.json`

```json
{ "schema_version": 2, "workouts": [ { "session_id": "…", "started_at": "…" } ] }
```

Neither half of that path is decorative — both were bugs:

1. **It must be a file, not a folder.** Shortcuts' `Get File` action opens a
   file at a known path; aimed at a directory it fails outright with *"the file
   couldn't be opened"*, and there is no dependable way to enumerate an
   arbitrary iCloud folder by path. v1 and v2 queued one JSON per walk in a
   folder and tried to list it.
2. **It must live in the Shortcuts folder.** `Get File` resolves paths
   *relative to the Shortcuts app's own iCloud container*, not to the iCloud
   Drive root, so a queue at `iCloud Drive/z1-walkingpad/…` is invisible to the
   phone — found nothing, reported nothing, walks piled up for days.

The menu-bar app folds any per-walk files left by older builds — in either
location — into the queue file on launch, and removes the empty folders.

The Shortcut reads the file, logs every workout, and only then deletes it,
finishing with a notification saying how many it imported.

That ordering is deliberate and was reversed in v3.1. Delete-then-log gives
at-most-once delivery, which sounds safer — but the Mac keeps a durable receipt
and never re-queues a walk, so any failure inside the Shortcut loses those walks
*permanently and silently*. After two consecutive Shortcut bugs, the better
posture is at-least-once: if something fails, the queue file survives and the
walks are retried. The worst case becomes a duplicate workout you can see and
delete, instead of a walk that quietly never existed.

The menu-bar app's queue directory and thresholds above are fixed in code, not
configurable. Only the standalone Python MCP server / CLI path (not this
automatic Mac pipeline) reads `Z1_HEALTH_QUEUE_DIR`, `Z1_HEALTH_MIN_ACTIVE_S`,
and `Z1_HEALTH_MIN_DISTANCE_M` as overrides for its own, separate queue writer.

## One real-world check

After the first walk, open WHOOP. Confirm exactly one Walking workout appears in
Apple Health and WHOOP. This physical iPhone/WHOOP check cannot be completed by
the Mac test suite.

Duplicate avoidance is deliberately conservative. The Mac remembers every
exported session ID and never recreates its queue file. The Shortcut consumes
that file before logging the workout, so it cannot retry the same walk. This is
at-most-once delivery: an iPhone crash in the tiny gap between consuming the
file and writing Health could miss a workout, but it will not create a duplicate.

Keep WHOOP's Apple Health read access for Workouts and Distance. To avoid WHOOP
writing the same workout back, disable its Workouts write permission when this
WalkingPad route is the workout source.

## Rebuilding the Shortcut

The signed install file is committed. Developers can rebuild it on macOS with:

```bash
./scripts/build_health_shortcut.sh
```
