# Z1 rebuild: who owns what (branch superapp-rebuild, started 2026-10-12)

Michael wants the Z1 WalkingPad app rebuilt. It becomes a **small normal-window app (no menu bar)**, clean and fast: keep the current layout and type feel and the blue accent, and remove the procedural sky, day/night, weather, gradients and animation bloat. The backend is fixed using the audit at `~/Projects/superfocus-mac/research/17-z1-walkingpad-audit.md`. Its data must be readable live by Superapp (`~/Projects/superapp/CONTRACT.md` § Z1).

| Owner | Owns | Must not touch |
|---|---|---|
| Codex session B (backend) | `macos/Sources/Z1Core/**` except the sky files below, `Z1CoreTestSuite`, `Z1Smoke`, `z1tests`, `macos/Tests`, `src/` (Python MCP), `docs/`, `shortcuts/` | `macos/Sources/Z1MenuBar/**` (→ frontend), `build-app.sh`, `Resources` |
| Opus frontend agent | `macos/Sources/Z1MenuBar/**` (may be renamed to `Z1App`), `macos/Resources`, `macos/build-app.sh`, the executable target in Package.swift, and the sky-only core files `Z1Core/SkyPhysics.swift`, `Z1Core/OpenMeteo.swift`, `Z1Core/SolarClock.swift` (may delete) | the rest of Z1Core |

Rules:
- Z1Core public API changes are **additive**. If the backend must break an API the UI uses, write it here under "API changes" with the new signature; the frontend adapts.
- Separate build dirs: backend `swift build --scratch-path .build-backend`, frontend `--scratch-path .build-frontend` (run from `macos/`).
- Never connect to the real treadmill over BLE in tests. Never run the old build-app.sh install to /Applications. Never launch Michael's installed app.
- Keep the Shortcuts Health-queue path and format (single file in the Shortcuts iCloud container, schema_version 2) and migrate the existing session history without loss.
- Local commits on `superapp-rebuild` are fine; never push.

## API changes
- Additive backend API: `LiveExport.publish(status:today:goalProgress:at:)` writes the Superapp `live.json` contract, including `todaySteps` and `todayKcal`. The app should call it after `recomputeToday()` for each received status and on a disconnect; the old driver-side live writer is being removed. The writer throttles connected updates to 1 Hz.
- `SessionStore` now owns automatic Health queue grouping for the production store. It creates a persisted first-launch cutover, combines belt segments separated by at most 10 minutes, queues only after the final 10-minute gap, and rechecks on launch or a timer. The frontend has removed its direct per-segment queue call. The production queue also rejects such premature calls. `HealthQueue.reconcile(sessions:)` is read-only and optional at launch. Existing pending iCloud entries are preserved; older uncertain history is not backfilled.
- For new sessions, pass `rawPadSteps: walk.rawPadSteps` and `stepModelVersion: walk.rawPadSteps == nil ? "gait-v1" : nil` to `WalkSession.init` so measured and estimated steps remain distinct.
- **Frontend follow-up in `receiveStatus`:** after `healthTracker.markConnectionDrop()` and persistence, call `scheduleHealthFinalization(deadline: healthTracker.finalizationDeadline)`. The tracker now gives a dropped moving run a two-minute deadline; without scheduling, that run waits for another status or app launch to enter history.

## Frontend notes (Opus frontend, 2026-10-12)
- The app target is now `Z1App` (`macos/Sources/Z1App`, product `Z1App`); `Z1MenuBar` is gone. Build it with `swift build --scratch-path .build-frontend --product Z1App`.
- Done: `SkyPhysics.swift`, `OpenMeteo.swift`, `SolarClock.swift` are deleted (commit 01ea820). The committed `Suites.swift` still names them until the backend commits its suite changes.
- Done (commit c3f5900): `LiveExport.publish` after `recomputeToday()` on every frame, on a disconnect and at quit; `rawPadSteps`/`stepModelVersion` on new `WalkSession`s; `scheduleHealthFinalization(deadline: healthTracker.finalizationDeadline)` after a drop. No direct Health-queue calls. This commit needs the backend's uncommitted Core (LiveExport, HealthQueue, Z1PadTransport, Status.padSteps) to build at HEAD.
- Z1Core API the app calls (keep these, or note the replacement under "API changes"): `Z1Treadmill` (`Status`, `Phase`, `statusUpdates`, `status.properties`, `connect`, `disconnect`, `start`, `stop`, `setSpeed`, `sleep`, `setWeight`, `setPersistStats`, `setStrideOverride`, `setDisplayUnits`, `clearStats`, `cancelConnectionNow`); `RemoteSessionTracker` (Codable, `observe`, `markConnectionDrop`, `finalizeIfDue`, `acknowledgeLog`, `openWalkTotals`, `finalizationDeadline`, `hasPendingLogs`); `CompletedWalk`; `SessionStore` (`init(url:)`, `reload`, `sessions`, `contains`, `append`, `totals(on:)`, `days(from:through:)`, `mostRecent`, `hourlyKcal`, `highScores`, `achievements`, `shouldMerge`); `WalkSession.init`; `DayTotals` (`addOpenWalk`); `HighScores`/`Achievement`; `StepSmoother`; `GaitModel.stepLengthM`; `Z1Metrics`; `Z1Units`; `HealthWeight.load`.
- The open walk (`z1.automaticHealthSession` in defaults) is now saved every 10 s mid-walk and at once on a drop, a finished walk or quit (was every frame).
- If the Health-queue writer or `live.json` needs a call from the app process, name it under "API changes"; walk completion happens in `TreadmillViewModel.logCompletedWalks`, frames land in `receiveStatus`.

## Backend notes (Codex, 2026-10-12)
- The backend test suite no longer calls the weather, sky or moon suites. The frontend may delete its three sky-only core files.
- `ReleaseDist` and `UpdateFeed` were removed with their obsolete tests; the app has no call sites for them.

## Codex review pass (2026-10-12)
- Current user direction supersedes the earlier visual brief: darker, smaller and less cluttered. Walk/History plus Settings; Records remains inside History. Native preview checks completed in both appearances; installed app and treadmill were not touched.
- Speed commands coalesce, Stop invalidates pending speed work, and non-finite input is rejected. Stop stays available while another command is busy. Health queue batches already published remain immutable until consumed; later sessions remain durable for the next batch.
- Verification: 255 simulated Swift checks and 23 default Python tests pass. Optimized local release bundle and fresh ZIP extraction pass strict recursive signature checks. This does not verify physical treadmill behavior or the iPhone Health import.
- `macos/build-app.sh` supports `Z1_BUILD_SCRATCH`, `Z1_BUILD_DIST` and optional nested-sandbox override. Builds only; no installation or launch. Detailed handoff: Documents/Codex/2026-10-12/i-want-you-to-check-out/outputs/READOUT.md.
