import Foundation
import Z1Core

/// Turns distances into places. Numbers do not land at a glance; places do —
/// "the Vondelpark, end to end" says more than 1.5 km ever will.
enum Equivalence {
    /// Daily distances, ascending. The largest entry at or below today's
    /// distance is shown. Dutch first, icons after — this walker starts from
    /// Amsterdam.
    private static let daily: [(km: Double, label: String)] = [
        (0.7, "Dam Square to Centraal"),
        (1.0, "ten football pitches, end to end"),
        (1.5, "the Vondelpark, end to end"),
        (1.7, "a lap of the Museumplein"),
        (2.7, "across the Golden Gate Bridge"),
        (4.0, "Central Park, top to bottom"),
        (5.0, "a parkrun"),
        (6.5, "around the Amsterdam canal ring"),
        (10.0, "a 10K"),
        (16.1, "the Dam tot Damloop"),
        (21.1, "a half marathon"),
        (42.2, "a marathon"),
    ]

    /// Lifetime journey out of Amsterdam, cumulative km to each town.
    private static let journey: [(km: Double, place: String)] = [
        (19, "Haarlem"), (42, "Leiden"), (57, "Den Haag"), (66, "Delft"),
        (78, "Rotterdam"), (100, "Dordrecht"), (130, "Breda"),
        (160, "Antwerpen"), (210, "Gent"), (250, "Brugge"),
        (315, "Lille"), (510, "Paris"),
    ]

    /// "≈ the Vondelpark, end to end", or nil below the smallest entry.
    static func daily(forMeters meters: Int) -> String? {
        let km = Double(meters) / 1_000
        guard let match = daily.last(where: { $0.km <= km }) else { return nil }
        return "≈ \(match.label)"
    }

    /// The line for a day too short to have earned an equivalence — aware of
    /// the clock instead of a shrug. Deterministic per hour, so it does not
    /// flicker between opens.
    static func flavor(at date: Date = Date(), distanceM: Int) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        // The sun and moon get first claim on this line: golden hour, an
        // imminent sunrise, or a good moon are worth a sentence.
        if let sun = SolarClock().sun(on: date) {
            let now = Double(hour) + Double(Calendar.current.component(.minute, from: date)) / 60
            let toSet = sun.setH - now
            let toRise = sun.riseH - now
            func clock(_ h: Double) -> String {
                String(format: "%d:%02d", Int(h) % 24, Int((h * 60).truncatingRemainder(dividingBy: 60)))
            }
            if toSet > 0, toSet < 0.85 {
                return "Golden hour — the sun sets at \(clock(sun.setH))"
            }
            if toRise > 0, toRise < 0.75 {
                return "The sun is up at \(clock(sun.riseH))"
            }
            if now > sun.setH || now < sun.riseH {
                let phase = MoonPhase.fraction(at: date)
                let illumination = MoonPhase.illumination(at: date)
                if illumination > 0.94 { return "Full moon tonight" }
                if illumination < 0.04 { return "New moon — the darkest sky of the month" }
                if (0.4...0.6).contains(phase) == false, illumination > 0.55 {
                    return phase < 0.5 ? "The moon is waxing, \(Int(illumination * 100))% lit"
                                       : "The moon is waning, \(Int(illumination * 100))% lit"
                }
            }
        }
        if distanceM > 0 {
            let toNext = daily.first { Double(distanceM) / 1_000 < $0.km }
            if let toNext {
                let remaining = toNext.km - Double(distanceM) / 1_000
                return String(format: "%.1f km to %@", remaining, toNext.label)
            }
        }
        switch hour {
        case 5..<10: return "The belt is warmest before the day gets loud"
        case 10..<14: return "Nothing walked yet — the morning is still open"
        case 14..<18: return "An afternoon leg would open the evening up"
        case 18..<23: return "A quiet lap before the day closes"
        default: return "The pad sleeps too"
        }
    }

    /// "Amsterdam → Leiden · 15 km to Den Haag"
    static func journeyLine(totalMeters: Int) -> String {
        let km = Double(totalMeters) / 1_000
        let passed = journey.last(where: { $0.km <= km })
        let next = journey.first(where: { $0.km > km })
        switch (passed, next) {
        case (nil, .some(let next)):
            return String(format: "%.0f km out of Amsterdam · %@ at %.0f km", km, next.place, next.km)
        case (.some(let passed), .some(let next)):
            return String(
                format: "Amsterdam → %@ · %.0f km to %@",
                passed.place, next.km - km, next.place
            )
        case (.some(let passed), nil):
            return "Amsterdam → \(passed.place)"
        case (nil, nil):
            return ""
        }
    }

    /// One calm sentence about a run of days — consistency framing, after the
    /// step-count literature: risk falls with regular movement and plateaus,
    /// so the sentence celebrates "most days", never streaks.
    static func narrative(for days: [DayTotals]) -> String {
        let walked = days.filter { !$0.isEmpty }
        guard !walked.isEmpty else { return "No walks yet in this window" }
        let totalMin = walked.reduce(0) { $0 + $1.activeDurationS } / 60
        let totalKm = Double(walked.reduce(0) { $0 + $1.distanceM }) / 1_000
        let avg = totalMin / walked.count
        return String(
            format: "Walked %d of %d days · %d min avg · %.1f km",
            walked.count, days.count, avg, totalKm
        )
    }
}
