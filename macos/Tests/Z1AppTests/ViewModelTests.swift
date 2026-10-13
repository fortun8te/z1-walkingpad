import Foundation
import Observation
import Testing
import UserNotifications
import Z1Core
@testable import Z1App

/// These exercise the real app model without creating a window or BLE central.
/// Run with Z1_PREVIEW=1; failing the guard must precede model construction.
@Suite(.serialized)
@MainActor
struct ViewModelTests {
    @Test func imperialSpeedDialPreservesActualBeltLimits() {
        let range = Z1Units.kmhToMph(1.7)...Z1Units.kmhToMph(5)
        #expect(SpeedDial.snapped(range.lowerBound, in: range) == range.lowerBound)
        #expect(SpeedDial.snapped(range.upperBound, in: range) == range.upperBound)
        #expect(SpeedDial.snapped(-1, in: range) == range.lowerBound)
        #expect(SpeedDial.snapped(100, in: range) == range.upperBound)
        #expect(abs(SpeedDial.snapped(2.34, in: range) - 2.3) < 0.000001)
    }

    private func model() throws -> TreadmillViewModel {
        try #require(TreadmillViewModel.isPreview, "Run app tests with Z1_PREVIEW=1 to isolate Bluetooth and storage")
        return TreadmillViewModel()
    }

    @Test func olderCommandResultsCannotOverwriteTheCurrentFailure() throws {
        let model = try model()
        let current = model.controlIntentGeneration
        let failure = NSError(domain: "AppTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop failed"])
        model.completeCommand(error: failure, retry: .stop, intent: current)
        #expect(model.failedCommand == .stop)
        model.completeCommand(error: nil, retry: .start, intent: current - 1)
        #expect(model.commandError == "Stop failed")
        model.completeCommand(error: failure, retry: .start, intent: current - 1)
        #expect(model.failedCommand == .stop)
        model.completeCommand(error: nil, retry: .stop, intent: current)
        #expect(model.commandError == nil)
        #expect(model.failedCommand == nil)
    }

    @Test func postStartSpeedFailureRetriesTheSpeedAndIgnoresCancellation() throws {
        let model = try model()
        let intent = model.controlIntentGeneration
        let failure = NSError(domain: "AppTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speed failed"])
        model.completeCommand(error: TreadmillViewModel.CommandFailure(retry: .speed(3.2), underlying: failure),
                              retry: .start, intent: intent)
        #expect(model.failedCommand == .speed(3.2))
        #expect(model.commandError == "Speed failed")
        model.completeCommand(error: TreadmillViewModel.CommandFailure(retry: .start, underlying: CancellationError()),
                              retry: .start, intent: intent)
        #expect(model.failedCommand == .speed(3.2))
    }

    @Test func shutdownRetiresLateCommandResults() throws {
        let model = try model()
        let intent = model.controlIntentGeneration
        model.prepareForShutdown()
        #expect(model.isShuttingDown)
        #expect(model.controlIntentGeneration > intent)
        let failure = NSError(domain: "AppTests", code: 3)
        model.completeCommand(error: failure, retry: .start, intent: intent)
        model.completeCommand(error: failure, retry: .start, intent: model.controlIntentGeneration)
        #expect(model.commandError == nil)
        #expect(model.failedCommand == nil)
    }

    @Test func extremeGoalInputIsBoundedWithoutArithmeticOverflow() throws {
        let model = try model()
        let originalGoal = model.dailyGoalMinutes
        defer { model.dailyGoalMinutes = originalGoal }
        var totals = DayTotals(day: Date())
        totals.activeDurationS = 3600
        model.dailyGoalMinutes = Int.max
        #expect(model.dailyGoalMinutes == 1440)
        #expect(model.goalProgress(for: totals) > 0)
        #expect(model.goalProgress(for: totals) < 1)
        model.dailyGoalMinutes = Int.min
        #expect(model.dailyGoalMinutes == 0)
        #expect(model.goalProgress(for: totals) == 0)
    }

    @Test func wakeOrClockChangeFinalizesAnOverdueWalk() throws {
        let model = try model()
        let now = Date()
        var status = Z1Treadmill.Status()
        status.phase = .ready
        status.hasTelemetry = true
        status.beltRunning = true
        status.speedKmh = 3
        status.elapsedS = 600
        status.distanceM = 500
        status.steps = 800
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(status, at: now.addingTimeInterval(-300), newSessionID: { "before-sleep" })
        status.beltRunning = false
        status.speedKmh = 0
        _ = tracker.observe(status, at: now.addingTimeInterval(-180))
        model.healthTracker = tracker
        model.refreshTimeDependentState()
        #expect(model.healthTracker.openWalkTotals == nil)
        let saved = try #require(model.sessionStore.sessions.first(where: { $0.id == "before-sleep" }))
        #expect(saved.activeDurationS == 600)
        #expect(saved.distanceM == 500)
        model.refreshTimeDependentState()
        #expect(model.sessionStore.sessions.filter { $0.id == "before-sleep" }.count == 1)
    }

    @Test func disablingRemindersQuittingOrWalkingCancelsAnAuthorizationWait() async throws {
        try #require(TreadmillViewModel.isPreview)
        let defaults = TreadmillViewModel.settingsStore
        let originalEnabled = defaults.object(forKey: TreadmillViewModel.remindersKey)
        let originalLog = defaults.object(forKey: TreadmillViewModel.reminderLogKey)
        defer {
            defaults.set(originalEnabled, forKey: TreadmillViewModel.remindersKey)
            defaults.set(originalLog, forKey: TreadmillViewModel.reminderLogKey)
        }
        for transition in ["disable", "quit", "walk"] {
            defaults.set([], forKey: TreadmillViewModel.reminderLogKey)
            var authorizationWait: CheckedContinuation<UNAuthorizationStatus, Never>?
            var submitted = 0
            let notifier = Notifier(isAvailable: { true }, authorizationStatus: {
                await withCheckedContinuation { authorizationWait = $0 }
            }, requestAuthorization: { true }, submit: { _ in submitted += 1 })
            let model = TreadmillViewModel(notifier: notifier)
            model.remindersEnabled = true
            let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 13)))
            model.scheduleReminderDelivery(now: now)
            let delivery = try #require(model.reminderDeliveryTask)
            for _ in 0..<100 where authorizationWait == nil { await Task.yield() }
            let continuation = try #require(authorizationWait)
            switch transition {
            case "quit": model.prepareForShutdown()
            case "walk":
                var running = model.status
                running.beltRunning = true
                running.speedKmh = 3
                model.setStatus(running)
            default: model.remindersEnabled = false
            }
            continuation.resume(returning: .authorized)
            await delivery.value
            #expect(submitted == 0)
            #expect(model.reminderDeliveryTask == nil)
            #expect((defaults.array(forKey: TreadmillViewModel.reminderLogKey) ?? []).isEmpty)
        }
    }

    @Test func pendingLoginApprovalRemainsRegisteredAndExternalChangesRefresh() throws {
        let model = try model()
        model.applyLoginItemState(.requiresApproval)
        #expect(model.launchAtLogin)
        #expect(model.loginItemMessage != nil)
        model.applyLoginItemState(.enabled)
        #expect(model.launchAtLogin)
        #expect(model.loginItemMessage == nil)
        model.applyLoginItemState(.disabled)
        #expect(!model.launchAtLogin)
        model.applyLoginItemState(.enabled, failure: "Could not unregister")
        #expect(model.launchAtLogin)
        #expect(model.loginItemMessage == "Could not unregister")
        model.applyLoginItemState(.unavailable)
        #expect(!model.launchAtLogin)
        #expect(model.loginItemMessage == nil)
    }

    @Test func partialLatestWeekCanMoveForwardToToday() throws {
        let model = try model()
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
        #expect(model.canGoForward(from: yesterday))
        #expect(!model.canGoForward(from: today))
        #expect(model.weekEnd(model.shiftedWeek(yesterday, by: 1)) == today)
    }

    @Test func historyCacheRefreshesOnlyWhenHistoryChanges() throws {
        let model = try model()
        let initialRevision = model.historyRevision
        model.refreshHistory()
        #expect(model.historyRevision == initialRevision)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        let walk = WalkSession(id: "app-cache", startedAt: start, endedAt: start.addingTimeInterval(900),
                               activeDurationS: 900, distanceM: 750, steps: 1200,
                               caloriesKcal: 50, exportedToHealth: false)
        #expect(model.sessionStore.append(walk))
        model.refreshHistory()
        #expect(model.savedSessionIDs.contains(walk.id))
        #expect(model.historyRevision == initialRevision + 1)
        model.refreshHistory()
        #expect(model.historyRevision == initialRevision + 1)
    }

    @Test func weeklyBarsMatchIndividualDayTotals() throws {
        let model = try model()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<35 {
            let start = try #require(calendar.date(byAdding: .day, value: -offset, to: today)).addingTimeInterval(-600)
            #expect(model.sessionStore.append(WalkSession(id: "day-\(offset)", startedAt: start,
                endedAt: start.addingTimeInterval(1800), activeDurationS: 1600,
                distanceM: 1100, steps: 1777, caloriesKcal: 90, exportedToHealth: false)))
        }
        model.refreshHistory()
        for offset in 0..<6 {
            let anchor = try #require(calendar.date(byAdding: .day, value: -offset * 7, to: today))
            let days = model.weekDays(endingOn: anchor)
            #expect(days.count == 7)
            for day in days { #expect(day == model.chartTotals(for: day.day)) }
        }
    }

    @Test func liveTotalsRemainStableAcrossIdenticalAndStoppedFrames() throws {
        let model = try model()
        var status = Z1Treadmill.Status()
        status.phase = .ready
        status.hasTelemetry = true
        status.beltRunning = true
        status.speedKmh = 3
        status.elapsedS = 600
        status.distanceM = 500
        status.steps = 800
        model.setStatus(status)
        model.observeWalk()
        let running = model.today
        for _ in 0..<100 { model.observeWalk() }
        #expect(model.today == running)
        status.speedKmh = 0
        status.beltRunning = false
        model.setStatus(status)
        model.observeWalk()
        let deadline = try #require(model.healthTracker.finalizationDeadline)
        for _ in 0..<100 { model.observeWalk() }
        #expect(model.healthTracker.finalizationDeadline == deadline)
        #expect(model.today == running)
        status.speedKmh = 3
        status.beltRunning = true
        status.elapsedS += 1
        model.setStatus(status)
        model.observeWalk()
        #expect(model.healthTracker.finalizationDeadline == nil)
        #expect(model.today.activeDurationS == running.activeDurationS + 1)
    }
}
