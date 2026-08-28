import Foundation

/// Current sky conditions for the window. Snapshots are cache-only (no
/// network); a missing cache means no weather overlay.
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    /// 0...1 fraction of sky covered.
    public var cloudCover: Double
    /// mm/h of whatever is falling.
    public var precipitation: Double
    /// WMO weather code (71+ family = snow).
    public var weatherCode: Int
    /// km/h at 10 m.
    public var windSpeed: Double
    /// Degrees, meteorological (wind FROM this direction).
    public var windDirection: Double
    /// hPa at the surface.
    public var pressure: Double
    /// Metres.
    public var visibility: Double
    public var fetchedAt: Date

    public init(
        cloudCover: Double,
        precipitation: Double,
        weatherCode: Int,
        windSpeed: Double = 8,
        windDirection: Double = 230,
        pressure: Double = 1_013,
        visibility: Double = 20_000,
        fetchedAt: Date
    ) {
        self.cloudCover = cloudCover
        self.precipitation = precipitation
        self.weatherCode = weatherCode
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.pressure = pressure
        self.visibility = visibility
        self.fetchedAt = fetchedAt
    }

    /// Old cached snapshots lack the new fields — decode them with calm
    /// defaults instead of throwing the whole cache away.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cloudCover = try values.decode(Double.self, forKey: .cloudCover)
        precipitation = try values.decode(Double.self, forKey: .precipitation)
        weatherCode = try values.decode(Int.self, forKey: .weatherCode)
        windSpeed = try values.decodeIfPresent(Double.self, forKey: .windSpeed) ?? 8
        windDirection = try values.decodeIfPresent(Double.self, forKey: .windDirection) ?? 230
        pressure = try values.decodeIfPresent(Double.self, forKey: .pressure) ?? 1_013
        visibility = try values.decodeIfPresent(Double.self, forKey: .visibility) ?? 20_000
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
    }

    public var isSnow: Bool { (71...77).contains(weatherCode) || (85...86).contains(weatherCode) }
    public var isRaining: Bool { precipitation > 0.05 && !isSnow }
    public var isSnowing: Bool { precipitation > 0.05 && isSnow }
    /// Clear enough to see stars and the moon.
    public var isClear: Bool { cloudCover < 0.45 && precipitation <= 0.05 }

    /// What kind of falling weather this actually is — drizzle is not a
    /// downpour and a flurry is not a snowstorm.
    public enum PrecipStyle: Sendable {
        case none, drizzle, rain, downpour, flurry, snow, heavySnow
    }

    public var precipStyle: PrecipStyle {
        guard precipitation > 0.02 else { return .none }
        if isSnow {
            if weatherCode == 71 || precipitation < 0.4 { return .flurry }
            if weatherCode == 75 || precipitation > 1.5 { return .heavySnow }
            return .snow
        }
        if (51...57).contains(weatherCode) || precipitation < 0.3 { return .drizzle }
        if weatherCode == 65 || weatherCode == 82 || (95...99).contains(weatherCode)
            || precipitation > 2.0 { return .downpour }
        return .rain
    }

    public var isFoggy: Bool { [45, 48].contains(weatherCode) || visibility < 2_000 }
    public var isThunderstorm: Bool { (95...99).contains(weatherCode) }
}

public enum OpenMeteo {
    static let cacheKey = "z1.weatherSnapshot"
    static let ttl: TimeInterval = 30 * 60

    public static func cached(defaults: UserDefaults = .standard) -> WeatherSnapshot? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(WeatherSnapshot.self, from: data)
    }

    /// Cached snapshot only — never hits the network.
    public static func snapshot(
        latitude: Double = 52.156,
        longitude: Double = 5.388,
        defaults: UserDefaults = .standard
    ) async -> WeatherSnapshot? {
        _ = latitude
        _ = longitude
        return cached(defaults: defaults)
    }
}

/// Where the moon is in its cycle, computed locally.
public enum MoonPhase {
    /// 0 = new, 0.5 = full, approaching 1 = new again.
    public static func fraction(at date: Date = Date()) -> Double {
        // Synodic month anchored to the new moon of 2000-01-06 18:14 UTC.
        let epoch = Date(timeIntervalSince1970: 947_182_440)
        let synodic = 29.530588853 * 86_400.0
        var phase = date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: synodic) / synodic
        if phase < 0 { phase += 1 }
        return phase
    }

    /// 0...1 how much of the disc is lit.
    public static func illumination(at date: Date = Date()) -> Double {
        (1 - cos(2 * .pi * fraction(at: date))) / 2
    }
}


/// Planetary K-index from NOAA space weather — the number that decides
/// whether the aurora reaches the Netherlands. Kp 7+ over a clear northern
/// horizon is a real, seen-from-Amersfoort event a few nights a year.
public enum SpaceWeather {
    static let cacheKey = "z1.kpIndex"
    static let ttl: TimeInterval = 60 * 60

    public static func cachedKp(defaults: UserDefaults = .standard) -> Double? {
        guard let data = defaults.data(forKey: cacheKey),
              let entry = try? JSONDecoder().decode([Double].self, from: data),
              entry.count == 2,
              Date().timeIntervalSince1970 - entry[1] < ttl * 4
        else { return nil }
        return entry[0]
    }

    /// Cache only — no NOAA fetch.
    public static func kp(defaults: UserDefaults = .standard) async -> Double? {
        cachedKp(defaults: defaults)
    }
}
