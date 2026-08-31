import Foundation

/// Derived high-scores — never stored separately, always computed from SessionStore.
/// Retains backward compat: old sessions.json files decode fine, high-scores just recompute.
public struct HighScores: Codable, Sendable, Equatable {
    public var longestWalk: WalkSession?      // max activeDurationS
    public var farthestWalk: WalkSession?     // max distanceM
    public var mostStepsWalk: WalkSession?    // max steps single walk
    public var mostKcalWalk: WalkSession?     // max caloriesKcal single walk
    public var mostStepsDay: DayTotalsCodable?
    public var mostKcalDay: DayTotalsCodable?
    public var mostDistanceDay: DayTotalsCodable?
    public var longestDayTime: DayTotalsCodable? // max activeDurationS in a day
    public var totalWalks: Int = 0
    public var totalDistanceM: Int = 0
    public var totalSteps: Int = 0
    public var totalKcal: Double = 0
    public var totalDurationS: Int = 0
    public var streakDays: Int = 0
    public var bestStreakDays: Int = 0

    public init(longestWalk: WalkSession? = nil, farthestWalk: WalkSession? = nil, mostStepsWalk: WalkSession? = nil, mostKcalWalk: WalkSession? = nil, mostStepsDay: DayTotalsCodable? = nil, mostKcalDay: DayTotalsCodable? = nil, mostDistanceDay: DayTotalsCodable? = nil, longestDayTime: DayTotalsCodable? = nil, totalWalks: Int = 0, totalDistanceM: Int = 0, totalSteps: Int = 0, totalKcal: Double = 0, totalDurationS: Int = 0, streakDays: Int = 0, bestStreakDays: Int = 0) {
        self.longestWalk = longestWalk; self.farthestWalk = farthestWalk; self.mostStepsWalk = mostStepsWalk; self.mostKcalWalk = mostKcalWalk; self.mostStepsDay = mostStepsDay; self.mostKcalDay = mostKcalDay; self.mostDistanceDay = mostDistanceDay; self.longestDayTime = longestDayTime; self.totalWalks = totalWalks; self.totalDistanceM = totalDistanceM; self.totalSteps = totalSteps; self.totalKcal = totalKcal; self.totalDurationS = totalDurationS; self.streakDays = streakDays; self.bestStreakDays = bestStreakDays
    }
}

/// Codable wrapper for DayTotals for agent export.
public struct DayTotalsCodable: Codable, Sendable, Equatable {
    public var day: Date
    public var walks: Int
    public var activeDurationS: Int
    public var distanceM: Int
    public var steps: Int
    public var caloriesKcal: Double
    public init(_ d: DayTotals) {
        day = d.day; walks = d.walks; activeDurationS = d.activeDurationS
        distanceM = d.distanceM; steps = d.steps; caloriesKcal = d.caloriesKcal
    }
}

public enum AchievementKind: String, Codable, Sendable, CaseIterable {
    case firstWalk = "first_walk"
    case walk10 = "walk_10"
    case walk50 = "walk_50"
    case walk100 = "walk_100"
    case distance100km = "distance_100km"
    case distance500km = "distance_500km"
    case steps5kDay = "steps_5k_day"
    case steps8kDay = "steps_8k_day"
    case steps10kDay = "steps_10k_day"
    case steps15kDay = "steps_15k_day"
    case kcal200Day = "kcal_200_day"
    case kcal500Day = "kcal_500_day"
    case hourWalk = "hour_walk"
    case twoHourWalk = "two_hour_walk"
    case streak3 = "streak_3"
    case streak7 = "streak_7"
    case streak30 = "streak_30"
    case earlyBird = "early_bird"
    case nightOwl = "night_owl"

    public var title: String {
        switch self {
        case .firstWalk: return "First Steps"
        case .walk10: return "10 Walks"
        case .walk50: return "50 Walks"
        case .walk100: return "100 Walks"
        case .distance100km: return "100 km"
        case .distance500km: return "500 km"
        case .steps5kDay: return "5K Day"
        case .steps8kDay: return "8K Day"
        case .steps10kDay: return "10K Day"
        case .steps15kDay: return "15K Day"
        case .kcal200Day: return "200 kcal Day"
        case .kcal500Day: return "500 kcal Day"
        case .hourWalk: return "Hour Walker"
        case .twoHourWalk: return "Endurance"
        case .streak3: return "3-Day Streak"
        case .streak7: return "Week Streak"
        case .streak30: return "Month Streak"
        case .earlyBird: return "Early Bird"
        case .nightOwl: return "Night Owl"
        }
    }
    public var systemName: String {
        switch self {
        case .firstWalk: return "flag"
        case .walk10: return "square.stack"
        case .walk50: return "square.stack.3d.up"
        case .walk100: return "square.stack.fill"
        case .distance100km: return "ruler"
        case .distance500km: return "map"
        case .steps5kDay, .steps8kDay, .steps10kDay, .steps15kDay: return "shoeprints.fill"
        case .kcal200Day, .kcal500Day: return "flame"
        case .hourWalk: return "timer"
        case .twoHourWalk: return "timer.circle"
        case .streak3: return "repeat"
        case .streak7: return "repeat.circle"
        case .streak30: return "calendar"
        case .earlyBird: return "sunrise"
        case .nightOwl: return "moon"
        }
    }
    public var description: String {
        switch self {
        case .firstWalk: return "Complete your first walk"
        case .walk10: return "10 walks recorded"
        case .walk50: return "50 walks recorded"
        case .walk100: return "100 walks recorded"
        case .distance100km: return "100 km total"
        case .distance500km: return "500 km total"
        case .steps5kDay: return "5,000 steps in a day"
        case .steps8kDay: return "8,000 steps in a day"
        case .steps10kDay: return "10,000 steps in a day"
        case .steps15kDay: return "15,000 steps in a day"
        case .kcal200Day: return "200 kcal in a day"
        case .kcal500Day: return "500 kcal in a day"
        case .hourWalk: return "Single walk ≥ 60 min"
        case .twoHourWalk: return "Single walk ≥ 120 min"
        case .streak3: return "Walk 3 days in a row"
        case .streak7: return "Walk 7 days in a row"
        case .streak30: return "Walk 30 days in a row"
        case .earlyBird: return "Walk before 7am"
        case .nightOwl: return "Walk after 10pm"
        }
    }
}

public struct Achievement: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: AchievementKind
    public var unlocked: Bool
    public var unlockedAt: Date?
    public var progress: Double // 0...1
}

public enum HighScoreComputer {
    public static func compute(from sessions: [WalkSession], calendar: Calendar = .current) -> HighScores {
        var hs = HighScores()
        guard !sessions.isEmpty else { return hs }

        hs.longestWalk = sessions.max(by: { $0.activeDurationS < $1.activeDurationS })
        hs.farthestWalk = sessions.max(by: { $0.distanceM < $1.distanceM })
        hs.mostStepsWalk = sessions.max(by: { $0.steps < $1.steps })
        hs.mostKcalWalk = sessions.max(by: { $0.caloriesKcal < $1.caloriesKcal })

        hs.totalWalks = sessions.count
        hs.totalDistanceM = sessions.reduce(0) { $0 + $1.distanceM }
        hs.totalSteps = sessions.reduce(0) { $0 + $1.steps }
        hs.totalKcal = sessions.reduce(0) { $0 + $1.caloriesKcal }
        hs.totalDurationS = sessions.reduce(0) { $0 + $1.activeDurationS }

        // Daily aggregates
        var byDay: [Date: DayTotals] = [:]
        for s in sessions {
            let d = calendar.startOfDay(for: s.startedAt)
            if byDay[d] == nil { byDay[d] = DayTotals(day: d) }
            byDay[d]!.add(s)
        }
        let days = Array(byDay.values)
        if let best = days.max(by: { $0.steps < $1.steps }) { hs.mostStepsDay = DayTotalsCodable(best) }
        if let best = days.max(by: { $0.caloriesKcal < $1.caloriesKcal }) { hs.mostKcalDay = DayTotalsCodable(best) }
        if let best = days.max(by: { $0.distanceM < $1.distanceM }) { hs.mostDistanceDay = DayTotalsCodable(best) }
        if let best = days.max(by: { $0.activeDurationS < $1.activeDurationS }) { hs.longestDayTime = DayTotalsCodable(best) }

        // Streaks
        let sortedDays = byDay.keys.sorted()
        var bestStreak = 0
        var curStreak = 0
        var prev: Date? = nil
        for day in sortedDays {
            if let p = prev, let nxt = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(nxt, inSameDayAs: day) {
                curStreak += 1
            } else {
                curStreak = 1
            }
            bestStreak = max(bestStreak, curStreak)
            prev = day
        }
        // current streak ending today
        let today = calendar.startOfDay(for: Date())
        curStreak = 0
        var cursor = today
        while byDay[cursor] != nil {
            curStreak += 1
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prevDay
        }
        hs.streakDays = curStreak
        hs.bestStreakDays = bestStreak
        return hs
    }

    public static func achievements(from sessions: [WalkSession], highScores: HighScores, calendar: Calendar = .current) -> [Achievement] {
        var out: [Achievement] = []
        func make(_ kind: AchievementKind, cond: Bool, progress: Double, at: Date? = nil) {
            let p = min(1, max(0, progress))
            out.append(Achievement(kind: kind, unlocked: cond, unlockedAt: cond ? (at ?? sessions.last?.startedAt) : nil, progress: cond ? 1 : p))
        }
        let total = highScores.totalWalks
        let totalDist = highScores.totalDistanceM
        let bestStepsDay = highScores.mostStepsDay?.steps ?? 0
        let bestKcalDay = highScores.mostKcalDay?.caloriesKcal ?? 0
        let longestSingle = highScores.longestWalk?.activeDurationS ?? 0
        let hasEarly = sessions.contains { calendar.component(.hour, from: $0.startedAt) < 7 }
        let hasNight = sessions.contains { calendar.component(.hour, from: $0.startedAt) >= 22 }

        make(.firstWalk, cond: total >= 1, progress: Double(total)/1)
        make(.walk10, cond: total >= 10, progress: Double(total)/10)
        make(.walk50, cond: total >= 50, progress: Double(total)/50)
        make(.walk100, cond: total >= 100, progress: Double(total)/100)
        make(.distance100km, cond: totalDist >= 100_000, progress: Double(totalDist)/100_000)
        make(.distance500km, cond: totalDist >= 500_000, progress: Double(totalDist)/500_000)
        make(.steps5kDay, cond: bestStepsDay >= 5_000, progress: Double(bestStepsDay)/5_000)
        make(.steps8kDay, cond: bestStepsDay >= 8_000, progress: Double(bestStepsDay)/8_000)
        make(.steps10kDay, cond: bestStepsDay >= 10_000, progress: Double(bestStepsDay)/10_000)
        make(.steps15kDay, cond: bestStepsDay >= 15_000, progress: Double(bestStepsDay)/15_000)
        make(.kcal200Day, cond: bestKcalDay >= 200, progress: bestKcalDay/200)
        make(.kcal500Day, cond: bestKcalDay >= 500, progress: bestKcalDay/500)
        make(.hourWalk, cond: longestSingle >= 3600, progress: Double(longestSingle)/3600)
        make(.twoHourWalk, cond: longestSingle >= 7200, progress: Double(longestSingle)/7200)
        make(.streak3, cond: highScores.bestStreakDays >= 3, progress: Double(highScores.bestStreakDays)/3)
        make(.streak7, cond: highScores.bestStreakDays >= 7, progress: Double(highScores.bestStreakDays)/7)
        make(.streak30, cond: highScores.bestStreakDays >= 30, progress: Double(highScores.bestStreakDays)/30)
        make(.earlyBird, cond: hasEarly, progress: hasEarly ? 1 : 0)
        make(.nightOwl, cond: hasNight, progress: hasNight ? 1 : 0)
        return out
    }
}
