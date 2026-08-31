import Foundation

/// Latest body mass. HealthKit is not available to Mac apps (Apple DTS 2025).
/// Reads Apple Health `export.xml` (iPhone Health → Profile → Export All
/// Health Data → AirDrop / iCloud Drive) or a small `weight.json`.
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
        let support = home.appendingPathComponent("Library/Application Support/Z1 WalkingPad")
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let downloads = home.appendingPathComponent("Downloads")
        let desktop = home.appendingPathComponent("Desktop")
        return [
            support.appendingPathComponent("export.xml"),
            support.appendingPathComponent(fileName),
            icloud.appendingPathComponent("apple_health_export/export.xml"),
            icloud.appendingPathComponent("export.xml"),
            downloads.appendingPathComponent("apple_health_export/export.xml"),
            downloads.appendingPathComponent("export.xml"),
            desktop.appendingPathComponent("apple_health_export/export.xml"),
            desktop.appendingPathComponent("export.xml"),
            home.appendingPathComponent(
                "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/z1-walkingpad/\(fileName)"
            ),
            home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Shortcuts/z1-walkingpad/\(fileName)"
            ),
        ]
    }

    public static func load(from files: [URL] = defaultFiles()) -> HealthWeightSample? {
        let samples = files.compactMap { url -> HealthWeightSample? in
            if url.pathExtension.lowercased() == "xml" {
                return parseExportXML(file: url)
            }
            return parse(file: url)
        }
        return samples.max { a, b in
            (a.measuredAt ?? .distantPast) < (b.measuredAt ?? .distantPast)
        }
    }

    /// Latest `HKQuantityTypeIdentifierBodyMass` in an Apple Health export.
    public static func parseExportXML(file: URL) -> HealthWeightSample? {
        guard let data = try? Data(contentsOf: file), data.count > 80 else { return nil }
        return parseExportXML(data: data)
    }

    public static func parseExportXML(data: Data) -> HealthWeightSample? {
        guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return nil
        }
        guard let re = try? NSRegularExpression(
            pattern: #"<Record\b[^>]*type="HKQuantityTypeIdentifierBodyMass"[^>]*/?>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        var best: HealthWeightSample?
        let range = NSRange(xml.startIndex..., in: xml)
        re.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match, let slice = Range(match.range, in: xml) else { return }
            let tag = String(xml[slice])
            func attr(_ name: String) -> String? {
                guard let a = try? NSRegularExpression(pattern: name + #"="([^"]+)""#),
                      let m = a.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                      let r = Range(m.range(at: 1), in: tag)
                else { return nil }
                return String(tag[r])
            }
            guard let valueRaw = attr("value"), let value = Double(valueRaw) else { return }
            let unit = (attr("unit") ?? "kg").lowercased()
            let kg = unit.contains("lb") ? value * 0.45359237 : value
            guard kg > 20, kg < 400 else { return }
            let when = attr("startDate").flatMap(parseHealthDate)
            let sample = HealthWeightSample(kg: kg, measuredAt: when, source: "apple-health-export")
            if best == nil || (when ?? .distantPast) > (best!.measuredAt ?? .distantPast) {
                best = sample
            }
        }
        return best
    }

    private static func parseHealthDate(_ raw: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        if let d = fmt.date(from: raw) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
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
