# Strava → Apple Health pipeline

The most automatic Apple Health route from a Mac: `treadmill_stop` uploads
each session to Strava as a Walk activity, and the Strava iOS app syncs it
into Apple Health natively (activity type, distance, time, calories —
per [Strava's docs](https://support.strava.com/hc/en-us/articles/216917527-Health-App-and-Strava)).

HealthKit itself is unavailable on macOS (verified:
`HKHealthStore.isHealthDataAvailable()` returns `false`), so the write into
Health happens on the iPhone inside the Strava app.

## One-time setup

1. **Create a free API app** at <https://www.strava.com/settings/api>
   (logged into your Strava account). Any name/website works; set the
   *Authorization Callback Domain* to `localhost`. Note the **Client ID**
   and **Client Secret**.

2. **Authorize** (on the Mac):

   ```bash
   .venv/bin/python -m z1_walkingpad_mcp.strava auth --client-id <ID> --client-secret <SECRET>
   ```

   Open the printed URL, approve, and you'll land on a dead `localhost`
   page — copy the `code` parameter from its URL and paste it back.
   Tokens are saved to `~/.z1-walkingpad/strava.json` (chmod 600) and
   refresh automatically; you never do this again.

3. **Test the chain:**

   ```bash
   .venv/bin/python -m z1_walkingpad_mcp.strava test
   ```

   uploads a 1-minute test walk. Check it appears on Strava, then on the
   iPhone confirm it lands in Apple Health (delete the test activity after).

4. **On the iPhone** (once): Strava app → *You → Settings → Manage Apps and
   Devices → Health → Send to Health* **on**, and allow Workouts write
   access when iOS asks.

From then on it's zero-touch: finish a walk, `treadmill_stop` returns the
summary with a `strava_activity_id`, and Health gets the workout when the
Strava app next syncs.

## Notes

- Uploads are best-effort: a Strava failure never breaks `treadmill_stop`;
  the summary gets a `strava_error` field instead.
- Calories in Health come from Strava's own estimate (based on the weight
  in your Strava profile); our MET estimate rides along in the activity
  description.
- Strava API rate limits (100/15 min, 1000/day) are irrelevant at one
  activity per session.
- The iCloud/Shortcut bridge (`docs/apple-health.md`) is the automatic
  fallback when Strava is unavailable. A successful Strava upload suppresses
  the queue file so Apple Health and WHOOP do not receive the same walk twice.
