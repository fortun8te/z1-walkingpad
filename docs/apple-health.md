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

3. In the Mac app: Settings → **Use latest Apple Health weight**. The app
   reads that file and uses it for ACSM kcal.

The file on the Mac is:

`~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/z1-walkingpad/weight.json`

# Apple Health → WHOOP

The Mac queues eligible finished WalkingPad workouts in iCloud Drive. The
iPhone Shortcut logs each queued walk as a Walking workout in Apple Health,
then deletes the queue file after logging all walks. WHOOP supplies heart rate,
calories, and Strain from the band you are already wearing.

## Easy setup

1. The Shortcut source is [`shortcuts/Z1 Import Health.xml`](../shortcuts/Z1%20Import%20Health.xml).
   Build and sign an installable `.shortcut` using the command below, then
   add it on the iPhone. Delete any older copy — v1 and v2 could not read the
   queue at all.
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
- Short belt stops can remain inside one workout. A stop of about 10 minutes
  finishes the workout.
- Apple Health receives the real start time, wall-clock duration, and belt
  distance.
- **Shortcut v3.1 also logs a step sample spanning the walk window.** If your
  iPhone was on you while you walked, it may have counted steps too. WalkingPad
  steps may be estimates; see "Your stride" in `../macos/README.md`.
- The bridge sends **no calorie sample** — WHOOP computes calories and Strain
  from the band's own heart rate and ignores anything we send.
- The Mac app connects automatically and watches the Z1 without starting
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

The queue writer publishes immutable batches. While a batch exists, newly
finished workouts stay safely in the local session history. After the phone
consumes that batch and its deletion syncs back, the Mac queues the next batch
on its next check, normally within one minute. An active resumed walk also
holds its group open, including after restoring the app, so the first segment
is not exported before the resumed segment finishes. This prevents the phone from
deleting a workout appended after it read the queue. The path and schema stay
compatible with the existing Shortcut. It does
not automatically re-queue historical sessions on launch: the older queue may
contain walks already imported on the phone, and the Mac cannot inspect Apple
Health. Reconcile that older file against Health before explicitly backfilling
history. Sessions marked `exportedToHealth: true` are treated as already
imported and are never newly queued.

The Mac also keeps local queued-session IDs in
`~/Library/Application Support/Z1 WalkingPad/health-queue-receipts.json`. This
prevents a completed walk from being recreated after the Shortcut deletes the
queue. That receipt records queueing, not successful Health import. The Mac
groups short belt runs with gaps up to 10 minutes and queues a workout only
after the final run has been stopped for 10 minutes.
The production queue refuses direct per-segment writes; the grouped writer is
the only automatic path into that file.

The Shortcut reads the file, logs every workout, and only then deletes it,
finishing with a notification saying how many it imported. Queueing a walk on
the Mac does not confirm that it reached Health or WHOOP.

That ordering is deliberate. If an action fails before the Shortcut deletes
the file, the workouts remain in the queue for a retry. A retry can create a
duplicate in Health if some workouts were logged before the failure.

The Mac app's queue path and thresholds are fixed in code. The Swift writer
rejects implausible workouts, including over 24 hours or over 7 km/h average.

## One real-world check

After the first walk, open WHOOP. Confirm exactly one Walking workout appears in
Apple Health and WHOOP. This physical iPhone/WHOOP check cannot be completed by
the Mac test suite.

The queue writer uses each session's stable ID and local receipts to avoid
queueing it twice. The Shortcut deletes the whole file after a successful import.
Without a phone-side receipt, the Mac cannot prove that a deleted queue entry
was imported; check Apple Health and WHOOP before backfilling old sessions.

Keep WHOOP's Apple Health read access for Workouts and Distance. To avoid WHOOP
writing the same workout back, disable its Workouts write permission when this
WalkingPad route is the workout source.

## Rebuilding the Shortcut

The signed install file is committed. Developers can rebuild it on macOS with:

```bash
./scripts/build_health_shortcut.sh
```
