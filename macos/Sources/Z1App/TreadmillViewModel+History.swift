import Foundation
import Z1Core

/// Today's totals, the daily goal, and the seven-day week History shows.
extension TreadmillViewModel {
    /// The walk still in progress (or inside its stop-grace window). It does
    /// not reach the store until the tracker finalizes it.
    var openWalk: CompletedWalk? { healthTracker.openWalkTotals }

    /// Saved IDs win over both tracker states during the save/acknowledge handoff.
    func displayTotals(addingTo stored: DayTotals) -> DayTotals {
        WalkDisplayTotals.addingTrackedWalks(
            to: stored, savedSessionIDs: Set(sessionStore.sessions.map(\.id)),
            tracker: healthTracker, weightKg: weightKg
        )
    }

    func hasPendingSave(on day: Date) -> Bool {
        _ = historyRevision
        return WalkDisplayTotals.hasPendingSave(
            on: day, savedSessionIDs: Set(sessionStore.sessions.map(\.id)), tracker: healthTracker
        )
    }

    // MARK: days

    /// Totals for any calendar day, today live (with the walk in progress).
    func totals(for day: Date) -> DayTotals {
        if Calendar.current.isDateInToday(day) { return today }
        _ = historyRevision
        _ = todayCoarse
        return displayTotals(addingTo: sessionStore.totals(on: day))
    }

    /// The same, with today rounded for the bars.
    func chartTotals(for day: Date) -> DayTotals {
        if Calendar.current.isDateInToday(day) { return todayCoarse }
        return totals(for: day)
    }

    // MARK: goal

    /// Minutes walked against the daily goal, 0…1.
    func goalProgress(for totals: DayTotals) -> Double {
        min(1, Double(totals.activeDurationS) / Double(max(1, dailyGoalMinutes * 60)))
    }

    /// "96/120 min".
    func goalText(for totals: DayTotals) -> String {
        "\(totals.activeDurationS / 60)/\(dailyGoalMinutes) min"
    }

    // MARK: week

    /// The seven days ending on `anchor` (never later than today), oldest
    /// first, today rounded for the bars.
    func weekDays(endingOn anchor: Date, calendar: Calendar = .current) -> [DayTotals] {
        let end = weekEnd(anchor, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        _ = historyRevision
        return sessionStore.days(from: start, through: end, calendar: calendar).map { chartTotals(for: $0.day) }
    }

    func weekEnd(_ anchor: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: anchor)
        let today = calendar.startOfDay(for: Date())
        return min(day, today)
    }

    func shiftedWeek(_ anchor: Date, by weeks: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: weeks * 7, to: anchor) ?? anchor
    }

    func canGoForward(from anchor: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: shiftedWeek(anchor, by: 1, calendar: calendar))
            <= calendar.startOfDay(for: Date())
    }
}
