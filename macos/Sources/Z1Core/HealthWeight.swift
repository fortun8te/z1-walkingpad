import Foundation

/// Latest body mass dropped by the iPhone Shortcut into the Shortcuts iCloud
/// folder. HealthKit is not available to Mac apps (Apple DTS, 2025).
public struct HealthWeightSample: Equatable, Sendable {
    public var kg: Double
    public var measuredAt: Date?
    public var source: String?

    public init(kg: Double, measuredAt: Date? = nil, source: String? = nil) {
        self.kg = kg
        self.measuredAt = measuredAt
        self.source = source
    }
}

public enum HealthWeight {
    public static let fileName = "weight.json"

    public static func defaultFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/z1-walkingpad/\(fileName)"
            ),
            home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Shortcuts/z1-walkingpad/\(fileName)"
            ),
            home.appendingPathComponent("Library/Application Support/Z1 WalkingPad/\(fileName)"),
        ]
    }

    public static func load(from files: [URL] = defaultFiles()) -> HealthWeightSample? {
        let samples = files.compactMap { parse(file: $0) }
        return samples.max { a, b in
            (a.measuredAt ?? .distantPast) < (b.measuredAt ?? .distantPast)
        }
    }

    public static func parse(file: URL) -> HealthWeightSample? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parse(data: data)
    }

    public static func parse(data: Data) -> HealthWeightSample? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let kg: Double?
        if let v = obj["kg"] as? Double { kg = v }
        else if let v = obj["kg"] as? Int { kg = Double(v) }
        else if let v = obj["weight_kg"] as? Double { kg = v }
        else if let v = obj["weightKg"] as? Double { kg = v }
        else if let v = obj["lb"] as? Double { kg = v * 0.45359237 }
        else { kg = nil }
        guard let kg, kg > 20, kg < 400 else { return nil }

        var measuredAt: Date?
        let dateKeys = ["measuredAt", "measured_at", "date", "startDate"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        for key in dateKeys {
            guard let raw = obj[key] as? String else { continue }
            measuredAt = iso.date(from: raw) ?? isoPlain.date(from: raw)
            if measuredAt != nil { break }
        }
        let source = obj["source"] as? String
        return HealthWeightSample(kg: kg, measuredAt: measuredAt, source: source)
    }
}
