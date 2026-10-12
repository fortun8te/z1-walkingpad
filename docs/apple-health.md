# Apple Health

HealthKit itself does not run on macOS. Apple's own DTS said so in 2025:
`HKHealthStore.isHealthDataAvailable()` is false, and Mac apps cannot read
the Health database. iOS apps (Strava, WHOOP, Metric, scale apps) talk to
HealthKit on the phone. Mac apps that show Health data import an
`export.xml`, or they get a file from an iPhone Shortcut.

This project uses the Shortcut route, same folder as the workout queue. The
Mac app does not read an `export.xml`.

## Latest weight → calories

1. On the iPhone, make a Shortcut:

   - Find Health Samples → Type is Weight → Sort by Start Date, latest first, Limit 1
   - Get Details of Health Sample → Value (kg)
   - Get Details of Health Sample → Start Date
   - Text:

     ```json
     {"kg": VALUE, "measuredAt": DATE, "source": "apple-health"}
     ```

     (Shortcuts can substitute the value and an ISO date. On a phone set to
     the Netherlands the number arrives with a decimal comma, `74,3`; the Mac
     reads that too.)
   - Save File → `Shortcuts/z1-walkingpad/weight.json`, overwrite.

2. Automation: Time of Day each morning, or App → Health / your scale app → Is Opened.

3. Nothing to switch on in the Mac app: it reads that file at launch, on wake,
   when its window comes forward and when a walk ends, and uses the newest
   weight for the ACSM kilocalories in its history and `live.json`. Without
   the file it uses the weight it last had, or 75 kg.

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
  steps are an estimate from belt distance and speed (see protocol.md).
- The bridge sends **no calorie sample** — WHOOP computes calories and Strain
  from the band's own heart rate and ignores anything we send.
- The Mac app connects automatically and watches the Z1 without starting
  or changing it. A physical-remote Start begins tracking a belt run. Two
  numbers matter and they are not the same:
  - A **belt run** (what History stores) ends after the belt has been stopped
    for **2 minutes**, or when the app sees the link drop and no telemetry
    follows for 2 minutes. A restart inside those 2 minutes continues the same
    run. Each run has its own stable ID.
  - A **Health workout** groups runs whose gaps are at most **10 minutes**. It
    is queued once the last run has been stopped for 10 minutes.
  A walk is never held open for hours: History and "Today" see a finished run
  about 2 minutes after Stop.
- If the app is quit (or crashes) mid-walk, the saved run is closed at the last
  moment the app saw it moving when the app next starts, so it cannot stay open
  and swallow the next walk.

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
on its next check. While a batch is waiting the Mac looks again after one
minute, then two, four, eight and finally every fifteen minutes, and checks
immediately whenever history changes, so an iPhone that is off for a week does
not keep the Mac waking every minute. An active resumed walk also
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

**Known leftover, still open on 12 October 2026.** Import is at-least-once.
The source has no Health lookup before writing. If workout 1 of 3 succeeds
and workout 2 fails, retrying writes workout 1 again. If the workout write
succeeds and its separate step write fails, the workout is already in Health
while the queue still exists. Retrying can duplicate both kinds of sample.
If file deletion succeeds and the notification fails, the batch has already
been consumed. The final notification counts queued entries, not confirmed
Health records.

A phone-side fix must use an Apple-exported action schema, not guessed action
identifiers. The current repository contains only the logging actions; the
installed Mac ActionKit health constants contain units, not the iPhone Health
query/filter schema. Apple's [Find and Filter guide](https://support.apple.com/en-lb/guide/shortcuts/apd3c845e881/ios)
confirms Find Health Samples exists but does not specify its serialized
parameters or prove that a particular workout filter works on the phone.
No executable deduplication patch has been made on this evidence alone.

The required retry behavior is:

- Match the same Walking workout window, including both start and end.
  A date-only or start-only match can mistake an unrelated workout for this
  entry. Do not round to the minute or match any overlapping workout.
- Match the window actually written by Log Workout. In v3.1 its start is the
  parsed `started_at` and its duration is `wall_duration_min`. Its calculated
  end can differ from `ended_at`: the Mac serializes date fields to whole
  seconds but rounds the original elapsed duration to 0.001 minute. An exact
  comparison with the queued `ended_at` can therefore miss an existing import.
- Check source and distance where the phone exposes them. The current Log
  Workout action does not store `session_id` as Health metadata, so dates and
  activity type alone cannot establish the queued entry's identity when
  unrelated sources have the same window. Treat an ambiguous match as a
  reconciliation case and preserve the batch.
- Handle the workout and step sample separately. An existing workout must not
  cause a missing step sample to be silently skipped, or an existing step sample
  to be written again. The step window uses `started_at` and `ended_at`.
- Keep deletion after every entry has been imported or positively reconciled.
  Any failed or ambiguous entry leaves the immutable batch in place. Run one
  importer at a time because separate query and write actions are not atomic.

An empty Health query is not sufficient proof of absence. Apple's
[Health authorization documentation](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
says read authorization is private and denied read access returns only samples
saved by the requesting app. Limited access can also hide older records.
Phone testing must establish that the query sees the relevant previously
imported records and any other sources used for reconciliation.

Before retrying an interrupted v3.1 import, compare the queued entries with
Health on the iPhone. Walks that earlier builds left in the queue may already
be in Health, and the Mac cannot check; do not discard or backfill them merely
because they are old. On 13 October 2026 the batch that had been waiting was
backed up and the queue file reset to an empty batch
(`{"schema_version":2,"workouts":[]}`), so new walks append to a clean file.
Whether the walks in the backup ever reached Health has not been verified.

To unblock implementation, export a minimal Shortcut authored on the iPhone
that finds Walking workouts and exposes their start, end, source and distance,
and a corresponding Steps query. This export supplies the real serialized
actions without running an import or changing existing Health records. Then
verify a new test batch, an already-imported entry, a failure partway through,
a workout-only partial import, and a same-start unrelated workout. Confirm
one workout and one step sample per queued entry, queue retention on failure,
and deletion only after complete reconciliation. These phone checks are still
pending. Mac XML validation cannot establish Health query behavior.

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

There is no WHOOP code in this repository: WHOOP only sees a walk through Apple
Health. The WHOOP sign-in helper (and its callback page, which can report
success before the token is saved) belongs to Superapp and is tracked there.

## Rebuilding the Shortcut

The XML source is committed. The signed install file is generated locally and
is not committed. Developers can rebuild it on macOS with:

```bash
./scripts/build_health_shortcut.sh
```
