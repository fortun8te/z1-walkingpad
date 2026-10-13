# WalkingPad and WHOOP

Reviewed 13 October 2026 against official documentation. The smallest path is
the existing **Mac → iCloud queue → iPhone Shortcut → Apple Health → WHOOP**
bridge. It needs no WHOOP sign-in in the Mac app. The bridge is implemented;
delivery of this exact Shortcut's workouts into WHOOP still needs an iPhone check.

## Set it up

1. Install and run **Z1 Import Health** using the [Apple Health setup](apple-health.md).
2. In WHOOP, open **More → App Settings → Integrations → Apple Health** and
   connect. Allow WHOOP to read Workouts and Distance in Apple's Health permissions.
3. Set the iPhone automation to run the Shortcut when WHOOP opens. Keep the
   band on during walks and let WHOOP sync. Refresh WHOOP after the import if needed.
4. After a new eligible walk, confirm its time and distance in Apple Health,
   then check for one Walking activity in WHOOP. Opening the app triggers an
   import attempt; it is not a delivery receipt.

WHOOP [documents activity imports from Apple Health][health]. It also lists
heart rate and active energy among imports, so the older claim that WHOOP
always ignores those fields is too broad. This bridge sends neither. Steps
are listed as an export to Apple Health, not an import: do not promise that
the Shortcut's step samples raise WHOOP's daily step count. The documented
30-day edit window is not a guarantee of historical backfill.

## What each route can do

| Route | Practical result | Decision |
| --- | --- | --- |
| Existing Apple Health bridge | Logs the actual walk window and belt distance on the phone; WHOOP supports importing workouts. | First choice. Exact phone behavior remains unverified. |
| WHOOP public API | Reads workout summaries, Strain and other authorized data. No public workout creation endpoint or workout write scope is documented. | An OAuth button would not solve walk logging. |
| WHOOP Bluetooth heart-rate broadcast | A Mac Bluetooth listener could show live band heart rate. | Does not create a WHOOP activity; defer this extra feature. |
| Strava → WHOOP | WHOOP now supports inbound cardio activities, including activities routed through Strava by other devices. | Viable alternative to investigate if the existing bridge fails; extra account, OAuth and sync state. |
| Android Health Connect → WHOOP | WHOOP supports activity import from Android's health store. | Requires an Android writer/companion; this iPhone Shortcut cannot use it. |
| WHOOP manual activity or auto-detection | The user can label an activity directly; auto-detection can identify sustained exertion. | Manual logging is a fallback; gentle desk walking may not trigger auto-detection. |

The [WHOOP API reference][api] exposes `read:workout`; its trusted healthcare
partner write endpoints concern lab services, not consumer workouts. Its
[developer FAQ][faq] confirms continuous heart rate is unavailable through
REST and points to BLE broadcast instead. Reading a matching workout later
could help verify delivery, but would introduce account and token management.

WHOOP's [May 2026 Strava announcement][strava] describes two-way activity
sync and preference for richer Strava data when imports overlap. Strava's
[activity creation API][strava-api] accepts activity type, start, duration and
distance with `activity:write`. A Z1-generated manual `Walk` without GPS
reaching WHOOP through that route is **untested**; neither announcement proves
that specific case. Do not add a second export path alongside Health before
testing duplicate behavior.

[Health Connect documentation][android] describes imported activities using
WHOOP heart-rate data. WHOOP's [activity detection explanation][detect] says
auto-detection generally needs about 15 minutes of sustained elevated heart
rate. A correctly labeled low-intensity walk can still have low Strain; the
app must not invent physiological effort from treadmill distance.

## Remaining reliability work

The existing Shortcut logs a Walking workout and a separate estimated step
sample, then deletes the batch. It does not attach the queue's `session_id`
as Health metadata. A failure halfway through can leave some records imported;
retrying can duplicate them. Mac receipts mean **queued**, not Health or WHOOP
confirmed. See [retry and reconciliation requirements](apple-health.md) before
changing the importer or backfilling old sessions.

Verify a fresh walk, a resumed walk, an overlapping WHOOP activity, and a
partial import on an iPhone. Compare exact workout windows and both record
types. First establish that a real exported Health query action can see prior
Shortcut records; do not guess its serialized schema. Keep the current batch
until every entry is imported or positively reconciled. These device checks
cannot be replaced by Swift tests or XML validation.

[health]: https://support.whoop.com/s/article/Apple-Health-Integration?language=en_US
[api]: https://developer.whoop.com/api/
[faq]: https://developer.whoop.com/docs/developing/support/
[strava]: https://www.whoop.com/us/en/thelocker/how-whoop-and-strava-work-together/
[strava-api]: https://developers.strava.com/docs/reference/#api-Activities-createActivity
[android]: https://support.whoop.com/s/article/Google-Health-Integration-For-Android
[detect]: https://www.whoop.com/us/en/thelocker/how-whoop-detects-and-labels-your-workouts-activities/
