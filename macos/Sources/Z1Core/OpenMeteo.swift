import Foundation

/// The sky over the desk, as Open-Meteo measured/modelled it a few minutes ago.
///
/// Every field beyond the original four decodes with a calm default, so an
/// old cached snapshot (or a test fixture with only cloud/precipitation/code)
/// never throws the cache away.
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    /// 0...1 fraction of sky covered, all levels.
    public var cloudCover: Double
    /// 0...1 per level: low (<2 km, cumulus/stratus), mid (altocumulus), high (cirrus).
    public var cloudLow: Double
    public var cloudMid: Double
    public var cloudHigh: Double
    /// mm/h of whatever is falling right now.
    public var precipitation: Double
    /// mm/h of the convective part (showers). Showers + sun = rainbow weather.
    public var showers: Double
    /// Largest precipitation rate in the hour either side of now (mm/h) —
    /// "rain nearby", the curtain a rainbow needs.
    public var precipitationNearby: Double
    /// Highest precipitation probability in the next two hours, 0...1.
    public var precipitationChanceSoon: Double
    /// WMO weather code.
    public var weatherCode: Int
    /// km/h at 10 m.
    public var windSpeed: Double
    /// Degrees, meteorological (wind FROM this direction).
    public var windDirection: Double
    /// km/h.
    public var windGusts: Double
    /// hPa at mean sea level.
    public var pressure: Double
    /// hPa change over the last three hours; nil when history is missing.
    public var pressureChange3h: Double?
    /// Metres.
    public var visibility: Double
    /// 0...1 relative humidity.
    public var humidity: Double
    /// W/m² global horizontal, direct horizontal and direct normal irradiance.
    /// Direct radiation is what says whether the sun is actually getting through.
    public var shortwave: Double?
    public var directRadiation: Double?
    public var directNormal: Double?
    /// J/kg — convective energy and the lightning potential index.
    public var cape: Double
    public var lightningPotential: Double
    public var fetchedAt: Date

    public init(
        cloudCover: Double,
        precipitation: Double,
        weatherCode: Int,
        cloudLow: Double? = nil,
        cloudMid: Double = 0,
        cloudHigh: Double = 0,
        showers: Double = 0,
        precipitationNearby: Double? = nil,
        precipitationChanceSoon: Double = 0,
        windSpeed: Double = 8,
        windDirection: Double = 230,
        windGusts: Double? = nil,
        pressure: Double = 1_013,
        pressureChange3h: Double? = nil,
        visibility: Double = 20_000,
        humidity: Double = 0.75,
        shortwave: Double? = nil,
        directRadiation: Double? = nil,
        directNormal: Double? = nil,
        cape: Double = 0,
        lightningPotential: Double = 0,
        fetchedAt: Date
    ) {
        self.cloudCover = cloudCover
        self.cloudLow = cloudLow ?? cloudCover
        self.cloudMid = cloudMid
        self.cloudHigh = cloudHigh
        self.precipitation = precipitation
        self.showers = showers
        self.precipitationNearby = precipitationNearby ?? precipitation
        self.precipitationChanceSoon = precipitationChanceSoon
        self.weatherCode = weatherCode
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.windGusts = windGusts ?? windSpeed * 1.6
        self.pressure = pressure
        self.pressureChange3h = pressureChange3h
        self.visibility = visibility
        self.humidity = humidity
        self.shortwave = shortwave
        self.directRadiation = directRadiation
        self.directNormal = directNormal
        self.cape = cape
        self.lightningPotential = lightningPotential
        self.fetchedAt = fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        cloudCover = try v.decode(Double.self, forKey: .cloudCover)
        precipitation = try v.decode(Double.self, forKey: .precipitation)
        weatherCode = try v.decode(Int.self, forKey: .weatherCode)
        fetchedAt = try v.decode(Date.self, forKey: .fetchedAt)
        cloudLow = try v.decodeIfPresent(Double.self, forKey: .cloudLow) ?? cloudCover
        cloudMid = try v.decodeIfPresent(Double.self, forKey: .cloudMid) ?? 0
        cloudHigh = try v.decodeIfPresent(Double.self, forKey: .cloudHigh) ?? 0
        showers = try v.decodeIfPresent(Double.self, forKey: .showers) ?? 0
        precipitationNearby = try v.decodeIfPresent(Double.self, forKey: .precipitationNearby) ?? precipitation
        precipitationChanceSoon = try v.decodeIfPresent(Double.self, forKey: .precipitationChanceSoon) ?? 0
        windSpeed = try v.decodeIfPresent(Double.self, forKey: .windSpeed) ?? 8
        windDirection = try v.decodeIfPresent(Double.self, forKey: .windDirection) ?? 230
        windGusts = try v.decodeIfPresent(Double.self, forKey: .windGusts) ?? windSpeed * 1.6
        pressure = try v.decodeIfPresent(Double.self, forKey: .pressure) ?? 1_013
        pressureChange3h = try v.decodeIfPresent(Double.self, forKey: .pressureChange3h)
        visibility = try v.decodeIfPresent(Double.self, forKey: .visibility) ?? 20_000
        humidity = try v.decodeIfPresent(Double.self, forKey: .humidity) ?? 0.75
        shortwave = try v.decodeIfPresent(Double.self, forKey: .shortwave)
        directRadiation = try v.decodeIfPresent(Double.self, forKey: .directRadiation)
        directNormal = try v.decodeIfPresent(Double.self, forKey: .directNormal)
        cape = try v.decodeIfPresent(Double.self, forKey: .cape) ?? 0
        lightningPotential = try v.decodeIfPresent(Double.self, forKey: .lightningPotential) ?? 0
    }

    public var isSnow: Bool { (71...77).contains(weatherCode) || (85...86).contains(weatherCode) }
    public var isRaining: Bool { precipitation > 0.05 && !isSnow }
    public var isSnowing: Bool { precipitation > 0.05 && isSnow }
    /// Clear enough to see stars and the moon.
    public var isClear: Bool { cloudCover < 0.45 && precipitation <= 0.05 }

    /// What kind of falling weather this actually is — drizzle is not a
    /// downpour and a flurry is not a snowstorm.
    public enum PrecipStyle: String, Sendable {
        case none, drizzle, rain, downpour, flurry, snow, heavySnow
    }

    public var precipStyle: PrecipStyle {
        guard precipitation > 0.02 else { return .none }
        if isSnow {
            if weatherCode == 71 || precipitation < 0.4 { return .flurry }
            if weatherCode == 75 || weatherCode == 86 || precipitation > 1.5 { return .heavySnow }
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

// MARK: - fetching

public enum OpenMeteo {
    static let cacheKey = "z1.weatherSnapshot"

    public static func cached(defaults: UserDefaults = .standard) -> WeatherSnapshot? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(WeatherSnapshot.self, from: data)
    }

    public static func store(_ snapshot: WeatherSnapshot, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    /// One short-lived, cookie-less session. Ten-second request timeout,
    /// no waiting for connectivity: offline simply means "use the cache".
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    static let currentFields = [
        "relative_humidity_2m", "precipitation", "rain", "showers", "snowfall",
        "weather_code", "cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
        "pressure_msl", "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m", "visibility",
        "shortwave_radiation", "direct_radiation", "direct_normal_irradiance",
        "cape", "lightning_potential",
    ]

    public static func url(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", latitude)),
            .init(name: "longitude", value: String(format: "%.3f", longitude)),
            .init(name: "current", value: currentFields.joined(separator: ",")),
            .init(name: "hourly", value: "pressure_msl,precipitation,precipitation_probability"),
            .init(name: "past_hours", value: "4"),
            .init(name: "forecast_hours", value: "3"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "GMT"),
        ]
        return c.url!
    }

    /// One request, no retries. Returns nil on any failure; the caller keeps
    /// whatever it had.
    public static func fetch(latitude: Double = 52.156, longitude: Double = 5.388) async -> WeatherSnapshot? {
        var request = URLRequest(url: url(latitude: latitude, longitude: longitude))
        request.setValue("Z1WalkingPad sky", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(data, now: Date())
    }

    /// Fetch, and on success write the cache. The cache survives offline.
    public static func refresh(latitude: Double, longitude: Double, defaults: UserDefaults = .standard) async -> WeatherSnapshot? {
        guard let fresh = await fetch(latitude: latitude, longitude: longitude) else { return nil }
        store(fresh, defaults: defaults)
        return fresh
    }

    /// Compatibility: cached snapshot only.
    public static func snapshot(latitude: Double = 52.156, longitude: Double = 5.388, defaults: UserDefaults = .standard) async -> WeatherSnapshot? {
        _ = (latitude, longitude)
        return cached(defaults: defaults)
    }

    // MARK: parsing

    struct Response: Decodable {
        struct Current: Decodable {
            var time: Double?
            var interval: Double?
            var relative_humidity_2m: Double?
            var precipitation: Double?
            var rain: Double?
            var showers: Double?
            var snowfall: Double?
            var weather_code: Int?
            var cloud_cover: Double?
            var cloud_cover_low: Double?
            var cloud_cover_mid: Double?
            var cloud_cover_high: Double?
            var pressure_msl: Double?
            var wind_speed_10m: Double?
            var wind_direction_10m: Double?
            var wind_gusts_10m: Double?
            var visibility: Double?
            var shortwave_radiation: Double?
            var direct_radiation: Double?
            var direct_normal_irradiance: Double?
            var cape: Double?
            var lightning_potential: Double?
        }
        struct Hourly: Decodable {
            var time: [Double]?
            var pressure_msl: [Double?]?
            var precipitation: [Double?]?
            var precipitation_probability: [Double?]?
        }
        var current: Current?
        var hourly: Hourly?
    }

    /// Turn the raw response into a snapshot. Public for tests.
    public static func parse(_ data: Data, now: Date) -> WeatherSnapshot? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data), let c = r.current else { return nil }
        // "current" sums precipitation over its own interval (15 min); make it a rate.
        let perHour = 3_600 / max(60, c.interval ?? 900)
        let precip = (c.precipitation ?? 0) * perHour
        let showers = (c.showers ?? 0) * perHour
        let t = c.time ?? now.timeIntervalSince1970

        var nearby = precip
        var chance = 0.0
        var change3h: Double?
        if let h = r.hourly, let times = h.time, !times.isEmpty {
            func value(_ series: [Double?]?, at i: Int) -> Double? {
                guard let s = series, i < s.count else { return nil }
                return s[i]
            }
            for (i, ht) in times.enumerated() {
                // Hourly precipitation is the sum over the *preceding* hour.
                if ht >= t - 3_600, ht <= t + 2 * 3_600, let p = value(h.precipitation, at: i) {
                    nearby = max(nearby, p)
                }
                if ht > t, ht <= t + 2 * 3_600, let pp = value(h.precipitation_probability, at: i) {
                    chance = max(chance, pp / 100)
                }
            }
            if let now = c.pressure_msl ?? interpolate(times, h.pressure_msl, at: t),
               let then = interpolate(times, h.pressure_msl, at: t - 3 * 3_600) {
                change3h = now - then
            }
        }

        return WeatherSnapshot(
            cloudCover: (c.cloud_cover ?? 0) / 100,
            precipitation: precip,
            weatherCode: c.weather_code ?? 0,
            cloudLow: (c.cloud_cover_low ?? c.cloud_cover ?? 0) / 100,
            cloudMid: (c.cloud_cover_mid ?? 0) / 100,
            cloudHigh: (c.cloud_cover_high ?? 0) / 100,
            showers: showers,
            precipitationNearby: nearby,
            precipitationChanceSoon: chance,
            windSpeed: c.wind_speed_10m ?? 8,
            windDirection: c.wind_direction_10m ?? 230,
            windGusts: c.wind_gusts_10m,
            pressure: c.pressure_msl ?? 1_013,
            pressureChange3h: change3h,
            visibility: c.visibility ?? 20_000,
            humidity: (c.relative_humidity_2m ?? 75) / 100,
            shortwave: c.shortwave_radiation,
            directRadiation: c.direct_radiation,
            directNormal: c.direct_normal_irradiance,
            cape: c.cape ?? 0,
            lightningPotential: c.lightning_potential ?? 0,
            fetchedAt: now
        )
    }

    /// Linear interpolation into an hourly series; nil outside it.
    static func interpolate(_ times: [Double], _ series: [Double?]?, at t: Double) -> Double? {
        guard let s = series, s.count == times.count, times.count >= 1 else { return nil }
        for i in 0..<(times.count - 1) where times[i] <= t && t <= times[i + 1] {
            guard let a = s[i], let b = s[i + 1] else { return nil }
            let f = (t - times[i]) / max(1, times[i + 1] - times[i])
            return a + (b - a) * f
        }
        if let first = times.first, abs(first - t) < 600 { return s[0] }
        return nil
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

    public static func name(at date: Date = Date()) -> String {
        let f = fraction(at: date)
        switch f {
        case ..<0.03, 0.97...: return "New moon"
        case ..<0.22: return "Waxing crescent"
        case ..<0.28: return "First quarter"
        case ..<0.47: return "Waxing gibbous"
        case ..<0.53: return "Full moon"
        case ..<0.72: return "Waning gibbous"
        case ..<0.78: return "Last quarter"
        default: return "Waning crescent"
        }
    }
}

/// Planetary K-index from NOAA space weather — the number that decides
/// whether the aurora reaches the Netherlands. Optional: nothing breaks
/// without it.
public enum SpaceWeather {
    static let cacheKey = "z1.kpIndex"
    static let ttl: TimeInterval = 60 * 60

    public static func cachedKp(defaults: UserDefaults = .standard) -> Double? {
        guard let entry = cacheEntry(defaults: defaults),
              Date().timeIntervalSince1970 - entry.at < ttl * 4
        else { return nil }
        return entry.kp
    }

    static func cacheEntry(defaults: UserDefaults) -> (kp: Double, at: Double)? {
        guard let data = defaults.data(forKey: cacheKey),
              let entry = try? JSONDecoder().decode([Double].self, from: data),
              entry.count == 2
        else { return nil }
        return (entry[0], entry[1])
    }

    /// Cached value if fresh, otherwise one NOAA request (10 s timeout).
    public static func kp(defaults: UserDefaults = .standard) async -> Double? {
        if let entry = cacheEntry(defaults: defaults), Date().timeIntervalSince1970 - entry.at < ttl {
            return entry.kp
        }
        let url = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Z1WalkingPad sky", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let value = parseKp(data)
        else { return cachedKp(defaults: defaults) }
        if let blob = try? JSONEncoder().encode([value, Date().timeIntervalSince1970]) {
            defaults.set(blob, forKey: cacheKey)
        }
        return value
    }

    /// NOAA has served both `[[header...],[row...]]` and `[{"Kp":...}]`.
    public static func parseKp(_ data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], let last = json.last else { return nil }
        if let row = last as? [String: Any] {
            if let v = row["Kp"] as? Double { return v }
            if let s = row["Kp"] as? String { return Double(s) }
            if let v = row["kp_index"] as? Double { return v }
        }
        if let row = last as? [Any], row.count > 1 {
            if let v = row[1] as? Double { return v }
            if let s = row[1] as? String { return Double(s) }
        }
        return nil
    }
}
