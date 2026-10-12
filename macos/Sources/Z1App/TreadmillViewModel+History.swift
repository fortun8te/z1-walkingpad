import Foundation
import Z1Core

/// Day, week and month maths for the almanac, and today's totals.
extension TreadmillViewModel {
    enum AlmanacLens: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            }
        }
    }

    /// The walk still in progress (or inside its stop-grace window). It does
    /// not reach the store until the tracker finalizes it.
    var openWalk: CompletedWalk? { healthTracker.openWalkTotals }

    // MARK: today

    /// Totals for any calendar day, today live (with the walk in progress).
    func totals(for day: Date) -> DayTotals {
        if Calendar.current.isDateInToday(day) { return today }
        _ = historyRevision
        return sessionStore.totals(on: day)
    }

    /// The same, with today rounded for charts.
    func chartTotals(for day: Date) -> DayTotals {
        if Calendar.current.isDateInToday(day) { return todayCoarse }
        _ = historyRevision
        return sessionStore.totals(on: day)
    }

    // MARK: goal

    /// Goal progress for a day's totals, honouring the goal kind.
    func goalProgress(for totals: DayTotals) -> Double {
        if goalIsSteps {
            return min(1, Double(totals.steps) / Double(max(1, dailyGoalSteps)))
        }
        return min(1, Double(totals.activeDurationS) / Double(max(1, dailyGoalMinutes * 60)))
    }

    /// "5,120/8,000" or "96/120 min" for a day.
    func goalText(for totals: DayTotals) -> String {
        goalIsSteps
            ? "\(totals.steps.formatted())/\(dailyGoalSteps.formatted())"
            : "\(totals.activeDurationS / 60)/\(dailyGoalMinutes) min"
    }

    // MARK: periods

    func periodStart(lens: AlmanacLens, anchor: Date, calendar: Calendar = .current) -> Date {
        switch lens {
        case .day:
            return calendar.startOfDay(for: anchor)
        case .week:
            let end = periodEnd(lens: .week, anchor: anchor, calendar: calendar)
            return calendar.date(byAdding: .day, value: -6, to: end) ?? end
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
        }
    }

    func periodEnd(lens: AlmanacLens, anchor: Date, calendar: Calendar = .current) -> Date {
        switch lens {
        case .day:
            return calendar.startOfDay(for: anchor)
        case .week:
            let day = calendar.startOfDay(for: anchor)
            let today = calendar.startOfDay(for: Date())
            return day > today ? today : day
        case .month:
            let start = calendar.dateInterval(of: .month, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
            let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return calendar.date(byAdding: .day, value: -1, to: next) ?? start
        }
    }

    func shiftedAnchor(lens: AlmanacLens, anchor: Date, by steps: Int, calendar: Calendar = .current) -> Date {
        switch lens {
        case .month: calendar.date(byAdding: .month, value: steps, to: anchor) ?? anchor
        case .week: calendar.date(byAdding: .day, value: steps * 7, to: anchor) ?? anchor
        case .day: calendar.date(byAdding: .day, value: steps, to: anchor) ?? anchor
        }
    }

    func canGoForward(lens: AlmanacLens, anchor: Date, calendar: Calendar = .current) -> Bool {
        let next = shiftedAnchor(lens: lens, anchor: anchor, by: 1, calendar: calendar)
        return calendar.startOfDay(for: next) <= calendar.startOfDay(for: Date())
    }

    /// Every day of the lens's period, oldest first, today rounded for charts.
    func almanacDays(lens: AlmanacLens, anchor: Date) -> [DayTotals] {
        let calendar = Calendar.current
        let start = periodStart(lens: lens, anchor: anchor, calendar: calendar)
        let end = periodEnd(lens: lens, anchor: anchor, calendar: calendar)
        _ = historyRevision
        return sessionStore.days(from: start, through: end, calendar: calendar).map { day in
            calendar.isDateInToday(day.day) ? todayCoarse : day
        }
    }

    /// The day's kcal by hour, with the walk in progress folded into today.
    func hourlyKcal(for day: Date) -> [Double] {
        _ = historyRevision
        var extra: WalkSession?
        if Calendar.current.isDateInToday(day) {
            _ = todayCoarse
            if let open = openWalk, !sessionStore.contains(id: open.id) {
                extra = WalkSession(
                    id: open.id,
                    startedAt: open.startedAt,
                    endedAt: open.endedAt,
                    activeDurationS: open.activeDurationS,
                    distanceM: open.distanceM,
                    steps: open.steps,
                    caloriesKcal: Z1Metrics.kcalPerMinute(open.avgSpeedKmh, weightKg: weightKg)
                        * Double(open.activeDurationS) / 60,
                    exportedToHealth: false
                )
            }
        }
        return sessionStore.hourlyKcal(on: day, extra: extra)
    }
}
