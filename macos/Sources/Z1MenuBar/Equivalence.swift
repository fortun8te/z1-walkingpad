import Foundation
import Z1Core

/// Short, checkable lines under Today. Distance, energy, or time — one of them,
/// whichever has something real to say.
enum Equivalence {
    private static let places: [(km: Double, label: String)] = [
        (0.40, "one canal block"),
        (0.80, "Dam to Centraal"),
        (1.00, "ten football pitches"),
        (1.50, "the Vondelpark, end to end"),
        (2.70, "the Golden Gate Bridge"),
        (3.50, "Schiphol's longest pier"),
        (5.00, "a 5K"),
        (8.00, "the canal ring, once around"),
        (10.0, "a 10K"),
        (21.1, "a half marathon"),
        (42.2, "a marathon"),
    ]

    private static let journey: [(km: Double, place: String)] = [
        (19, "Haarlem"),
        (42, "Leiden"),
        (57, "Den Haag"),
        (78, "Rotterdam"),
        (130, "Breda"),
        (210, "Gent"),
        (510, "Paris"),
    ]

    static func daily(forMeters meters: Int) -> String? {
        let km = Double(meters) / 1_000
        guard let match = places.last(where: { $0.km <= km }) else { return nil }
        return match.label
    }

    /// Body-fat energy is ~7.7 kcal/g. Dietary fat is 9 kcal/g.
    static func energy(kcal: Double) -> String? {
        guard kcal >= 40 else { return nil }
        let fatG = kcal / 7.7
        if fatG < 12 {
            return String(format: "≈ %.0f g of body fat at a deficit", fatG)
        }
        return String(format: "≈ %.0f g of fat, if this is extra work", fatG)
    }

    static func caption(distanceM: Int, kcal: Double, minutes: Int) -> String {
        if minutes >= 20, let energy = energy(kcal: kcal) {
            return energy
        }
        if let place = daily(forMeters: distanceM) {
            return place
        }
        if let energy = energy(kcal: kcal) {
            return energy
        }
        if minutes >= 8 {
            return "\(minutes) min off the chair"
        }
        if distanceM <= 0 {
            return "Nothing on the belt yet"
        }
        return String(format: "%.0f m so far", Double(distanceM))
    }

    static func flavor(distanceM: Int) -> String {
        caption(distanceM: distanceM, kcal: 0, minutes: 0)
    }

    static func journeyLine(totalMeters: Int) -> String {
        let km = Double(totalMeters) / 1_000
        let passed = journey.last(where: { $0.km <= km })
        let next = journey.first(where: { $0.km > km })
        switch (passed, next) {
        case (nil, .some(let next)):
            return String(format: "%.0f km out · %@ at %.0f km", km, next.place, next.km)
        case (.some(let passed), .some(let next)):
            return String(format: "Amsterdam → %@ · %.0f km to %@", passed.place, next.km - km, next.place)
        case (.some(let passed), nil):
            return "Amsterdam → \(passed.place)"
        case (nil, nil):
            return ""
        }
    }

    static func narrative(for days: [DayTotals]) -> String {
        let walked = days.filter { !$0.isEmpty }
        guard !walked.isEmpty else { return "No walks in this window" }
        let totalMin = walked.reduce(0) { $0 + $1.activeDurationS } / 60
        let totalKm = Double(walked.reduce(0) { $0 + $1.distanceM }) / 1_000
        return String(
            format: "%d of %d days · %d min · %.1f km",
            walked.count, days.count, totalMin, totalKm
        )
    }
}
