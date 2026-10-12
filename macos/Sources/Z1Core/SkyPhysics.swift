import Foundation

// The sky's physics, kept pure so every phenomenon can be unit-checked:
// a rainbow only where optics allow one, god rays only when the measured
// direct beam says the sun is really getting through, a heavier sky only
// when the barometer is really falling.

@inline(__always) func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

@inline(__always) public func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

// MARK: - barometer

/// Three-hour pressure tendency, in the bands shipping forecasts use
/// (steady < 1 hPa, "quickly" from 3.6 hPa / 3 h).
public enum PressureTendency: String, Sendable, Equatable {
    case risingFast, rising, steady, falling, fallingFast

    public init(change3h: Double) {
        switch change3h {
        case 3.6...: self = .risingFast
        case 1.0..<3.6: self = .rising
        case ...(-3.6): self = .fallingFast
        case ...(-1.0): self = .falling
        default: self = .steady
        }
    }

    public var word: String {
        switch self {
        case .risingFast: "rising fast"
        case .rising: "rising"
        case .steady: "steady"
        case .falling: "falling"
        case .fallingFast: "falling fast"
        }
    }

    /// How much weight the trend adds to the sky: falling air is incoming weather.
    public var weight: Double {
        switch self {
        case .risingFast: -0.20
        case .rising: -0.10
        case .steady: 0
        case .falling: 0.18
        case .fallingFast: 0.35
        }
    }
}

// MARK: - the sun's direct beam

public enum SunBeam {
    /// Kasten–Young relative air mass.
    public static func airMass(elevation e: Double) -> Double {
        guard e > -0.5 else { return 40 }
        let el = max(0, e)
        return 1 / (sin(el * .pi / 180) + 0.50572 * pow(el + 6.07995, -1.6364))
    }

    /// Clear-sky direct normal irradiance (Meinel model), W/m².
    public static func clearSkyDNI(elevation e: Double) -> Double {
        guard e > 0 else { return 0 }
        return 1_353 * pow(0.7, pow(airMass(elevation: e), 0.678))
    }

    /// 0...1 — how much of the clear-sky direct beam is reaching the ground.
    /// Measured DNI when the feed has it, direct-horizontal next, and a
    /// cloud-layer estimate only when neither exists (old caches, simulator).
    public static func fraction(weather w: WeatherSnapshot?, elevation e: Double) -> Double {
        guard e > 0.5 else { return 0 }
        guard let w else { return 1 }
        let clear = clearSkyDNI(elevation: e)
        if let dni = w.directNormal, clear > 40 {
            return clamp01(dni / (clear * 0.85))
        }
        if let direct = w.directRadiation, clear > 40 {
            let horizontal = clear * sin(e * .pi / 180)
            return clamp01(direct / max(1, horizontal * 0.85))
        }
        return estimatedFraction(weather: w)
    }

    /// Without radiation data: low cloud blocks most, cirrus barely.
    public static func estimatedFraction(weather w: WeatherSnapshot) -> Double {
        let blocked = 1 - (1 - w.cloudLow * 0.95) * (1 - w.cloudMid * 0.75) * (1 - w.cloudHigh * 0.25)
        let rain = w.precipitation > 0.05 ? 0.25 : 0
        return clamp01(1 - blocked - rain)
    }

    /// 0...1 strength of the sun "breaking through": a mostly-cloudy sky
    /// in which the direct beam is nevertheless strong right now. That is
    /// exactly when crepuscular rays show.
    public static func breakthrough(sunFraction f: Double, cloudCover c: Double, elevation e: Double) -> Double {
        guard e > 1 else { return 0 }
        return smoothstep(0.40, 0.70, c) * smoothstep(0.35, 0.70, f) * smoothstep(1, 5, e)
    }
}

// MARK: - rainbow optics

public struct RainbowGeometry: Equatable, Sendable {
    /// The anti-solar point: opposite the sun, as far below the horizon as the sun is above.
    public var centerAzimuth: Double
    public var centerElevation: Double
    public var primaryRadius: Double
    public var secondaryRadius: Double
    /// Highest point of the primary bow above the horizon.
    public var apexElevation: Double { centerElevation + primaryRadius }
}

public enum Rainbow {
    /// Red edge of the primary bow (degrees from the anti-solar point).
    public static let primaryRadius = 42.0
    /// Secondary bow, colours reversed.
    public static let secondaryRadius = 51.0

    public static func geometry(sunAzimuth: Double, sunElevation: Double) -> RainbowGeometry {
        var az = (sunAzimuth + 180).truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        return RainbowGeometry(
            centerAzimuth: az,
            centerElevation: -sunElevation,
            primaryRadius: primaryRadius,
            secondaryRadius: secondaryRadius
        )
    }

    /// 0...1. Needs the sun between the horizon and 42° (above that the whole
    /// bow sits below the horizon), the sun actually out, rain in the air
    /// nearby, and no snow or fog. Brightest with a low sun.
    public static func strength(
        sunElevation e: Double,
        sunFraction: Double,
        rainNearby: Double,
        isSnow: Bool,
        fog: Double
    ) -> Double {
        guard e > 0, e < primaryRadius, !isSnow, fog < 0.5 else { return 0 }
        let altitude = smoothstep(0, 2, e) * (1 - smoothstep(primaryRadius - 8, primaryRadius, e))
        let sun = smoothstep(0.30, 0.70, sunFraction)
        let rain = smoothstep(0.05, 0.6, rainNearby)
        return clamp01(altitude * sun * rain * (1 - fog * 2))
    }
}

// MARK: - the whole scene

/// Falling weather, typed.
public enum PrecipKind: String, Sendable, Equatable {
    case none, drizzle, rain, showers, downpour, sleet, flurry, snow, heavySnow

    public var isSnowlike: Bool { [.flurry, .snow, .heavySnow].contains(self) }
}

/// Every number the renderer needs, derived once per minute from real data.
public struct SkyScene: Equatable, Sendable {
    public var date: Date
    public var sunElevation: Double
    public var sunAzimuth: Double
    public var moonElevation: Double
    public var moonAzimuth: Double
    public var moonIllumination: Double
    /// 0 new → 0.5 full → 1 new.
    public var moonPhase: Double
    /// 0 full daylight … 1 astronomical night.
    public var darkness: Double
    /// 0...1 inside golden hour (sun −4°…+6°, peaking near 1°).
    public var goldenHour: Double
    /// 0...1 inside blue hour (sun −6°…−4°).
    public var blueHour: Double
    public var cloudLow: Double
    public var cloudMid: Double
    public var cloudHigh: Double
    public var cloudTotal: Double
    /// Showers / high CAPE: puffy, towering cloud rather than a lid.
    public var convective: Double
    /// Measured share of the direct beam reaching the ground.
    public var sunFraction: Double
    public var breakthrough: Double
    public var rainbow: Double
    public var rainbowGeometry: RainbowGeometry
    public var precip: PrecipKind
    /// 0...1 how hard it falls.
    public var precipIntensity: Double
    public var fog: Double
    public var haze: Double
    public var stars: Double
    /// 0...1 weight of the sky: cloud, low pressure and a falling barometer.
    public var heaviness: Double
    public var pressure: Double
    public var tendency: PressureTendency?
    public var windSpeed: Double
    /// Meteorological: wind comes FROM here.
    public var windDirection: Double
    /// Flashes per minute-ish, 0...1.
    public var lightning: Double
    public var aurora: Double
    /// 22° ice halo round sun or moon (thin cirrostratus).
    public var halo: Double
    public var hasWeather: Bool
}

public enum SkyModel {
    public static func evaluate(
        date: Date,
        weather w: WeatherSnapshot?,
        clock: SolarClock = SolarClock(),
        kp: Double = 0
    ) -> SkyScene {
        let sun = clock.position(at: date)
        let moon = clock.moonPosition(at: date)
        let e = sun.elevation
        let illumination = MoonPhase.illumination(at: date)

        let low = w?.cloudLow ?? 0
        let mid = w?.cloudMid ?? 0
        let high = w?.cloudHigh ?? 0
        let total = w?.cloudCover ?? 0
        let code = w?.weatherCode ?? 0

        // Visibility → fog/haze.
        let vis = w?.visibility ?? 30_000
        var fog = 1 - smoothstep(300, 5_000, vis)
        if [45, 48].contains(code) { fog = max(fog, 0.8) }
        let humidity = w?.humidity ?? 0.6
        let haze = clamp01((1 - smoothstep(6_000, 25_000, vis)) * 0.6 + smoothstep(0.80, 0.98, humidity) * 0.3) * (1 - fog)

        let sunFraction = SunBeam.fraction(weather: w, elevation: e)
        // Cirrus veils do not make god rays; only low/mid cloud with gaps does.
        let solidCover = w == nil ? 0 : 1 - (1 - low) * (1 - mid * 0.85)
        let breakthrough = SunBeam.breakthrough(sunFraction: sunFraction, cloudCover: max(solidCover, total * 0.7), elevation: e) * (1 - fog)

        // Precipitation type and weight.
        let rate = w?.precipitation ?? 0
        var precip: PrecipKind = .none
        if let w, rate > 0.02 {
            switch w.precipStyle {
            case .none: precip = .none
            case .drizzle: precip = .drizzle
            case .rain: precip = w.showers > rate * 0.5 ? .showers : .rain
            case .downpour: precip = .downpour
            case .flurry: precip = .flurry
            case .snow: precip = .snow
            case .heavySnow: precip = .heavySnow
            }
            if [56, 57, 66, 67].contains(code) { precip = .sleet }
        }
        let intensity = precip == .none ? 0 : clamp01(log2(1 + rate * 2) / 4)

        let isSnow = w?.isSnow ?? false
        let nearby = max(rate, w?.precipitationNearby ?? 0, w?.showers ?? 0)
        let rainbow = Rainbow.strength(
            sunElevation: e,
            sunFraction: sunFraction,
            rainNearby: nearby,
            isSnow: isSnow,
            fog: fog
        )

        let darkness = smoothstep(0, -15, e) // 0 at sunset, 1 by −15°
        let golden = e > -4 && e < 6 ? smoothstep(-4, 0.5, e) * (1 - smoothstep(2, 6, e)) : 0
        let blue = e > -7 && e < -3 ? smoothstep(-7, -5.5, e) * (1 - smoothstep(-4.5, -3, e)) : 0

        let clarity = clamp01(1 - (low + 0.85 * mid + 0.45 * high))
        let moonWash = moon.elevation > 0 ? illumination * 0.45 : 0
        let stars = pow(darkness, 1.4) * clarity * (1 - fog) * (1 - moonWash) * (1 - haze * 0.6)

        let tendency = w?.pressureChange3h.map { PressureTendency(change3h: $0) }
        let pressure = w?.pressure ?? 1_013
        let lowPressure = smoothstep(1_012, 985, pressure)
        let heaviness = clamp01(total * 0.55 + lowPressure * 0.25 + (tendency?.weight ?? 0) + intensity * 0.25)

        var lightning = 0.0
        if (95...99).contains(code) { lightning = code == 95 ? 0.6 : 1 }
        if let lpi = w?.lightningPotential, lpi > 0 { lightning = max(lightning, clamp01(0.3 + lpi / 20)) }
        if let cape = w?.cape, cape > 1_200, rate > 1 { lightning = max(lightning, 0.25) }

        let convective = clamp01(
            ((80...82).contains(code) || (95...99).contains(code) ? 0.8 : 0)
                + smoothstep(300, 1_500, w?.cape ?? 0) * 0.6
                + ((w?.showers ?? 0) > 0.05 ? 0.4 : 0)
        )

        let auroraKp = smoothstep(6.0, 8.0, kp)
        let aurora = auroraKp * pow(darkness, 2) * clarity * (1 - fog)

        let thinCirrus = smoothstep(0.30, 0.65, high) * (1 - smoothstep(0.15, 0.45, low + mid))
        let haloSource = e > 3 ? sunFraction : (moon.elevation > 3 ? illumination * darkness : 0)
        let halo = thinCirrus * smoothstep(0.3, 0.8, haloSource) * (1 - fog)

        return SkyScene(
            date: date,
            sunElevation: e,
            sunAzimuth: sun.azimuth,
            moonElevation: moon.elevation,
            moonAzimuth: moon.azimuth,
            moonIllumination: illumination,
            moonPhase: MoonPhase.fraction(at: date),
            darkness: darkness,
            goldenHour: golden,
            blueHour: blue,
            cloudLow: low,
            cloudMid: mid,
            cloudHigh: high,
            cloudTotal: total,
            convective: convective,
            sunFraction: sunFraction,
            breakthrough: breakthrough,
            rainbow: rainbow,
            rainbowGeometry: Rainbow.geometry(sunAzimuth: sun.azimuth, sunElevation: e),
            precip: precip,
            precipIntensity: intensity,
            fog: fog,
            haze: haze,
            stars: stars,
            heaviness: heaviness,
            pressure: pressure,
            tendency: tendency,
            windSpeed: w?.windSpeed ?? 6,
            windDirection: w?.windDirection ?? 230,
            lightning: lightning,
            aurora: aurora,
            halo: halo,
            hasWeather: w != nil
        )
    }
}

// MARK: - words

public enum SkyNarrative {
    static func timeString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func compass(_ azimuth: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        var a = azimuth.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return names[Int((a + 22.5) / 45) % 8]
    }

    /// The weather in a few words, with the phenomenon first when there is one.
    public static func phrase(scene s: SkyScene, weather w: WeatherSnapshot?) -> String {
        if s.rainbow > 0.25 { return "Rainbow in the \(compass(s.rainbowGeometry.centerAzimuth))" }
        if s.lightning > 0.5 { return "Thunderstorm" }
        if s.breakthrough > 0.35 { return "Sun breaking through" }
        if s.aurora > 0.2 { return "Aurora possible to the north" }
        guard let w else { return s.darkness > 0.5 ? "Night" : "Daylight" }
        switch s.precip {
        case .drizzle: return "Drizzle"
        case .rain: return s.precipIntensity < 0.3 ? "Light rain" : "Rain"
        case .showers: return s.sunFraction > 0.3 ? "Sunny showers" : "Showers"
        case .downpour: return "Heavy rain"
        case .sleet: return "Freezing rain"
        case .flurry: return "Snow flurries"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy snow"
        case .none: break
        }
        if s.fog > 0.6 { return "Fog" }
        if s.fog > 0.3 || s.haze > 0.45 { return "Mist" }
        if s.halo > 0.35 { return s.sunElevation > 3 ? "Halo around the sun" : "Halo around the moon" }
        switch w.cloudCover {
        case ..<0.12: return s.darkness > 0.6 ? "Clear night" : "Clear"
        case ..<0.40: return "Mostly clear"
        case ..<0.75: return "Partly cloudy"
        case ..<0.93: return "Mostly cloudy"
        default: return "Overcast"
        }
    }

    /// e.g. "Light rain · 1008 hPa falling · sunset 19:32"
    public static func summary(scene s: SkyScene, weather w: WeatherSnapshot?, clock: SolarClock, calendar: Calendar = .current) -> String {
        var parts = [phrase(scene: s, weather: w)]
        if w != nil {
            var p = "\(Int(s.pressure.rounded())) hPa"
            if let t = s.tendency { p += " \(t.word)" }
            parts.append(p)
        }
        if let sun = clock.sun(on: s.date, calendar: calendar) {
            let h = hourOfDay(s.date, calendar: calendar)
            let label = h < sun.riseH || h >= sun.setH ? "sunrise" : "sunset"
            // The almanac routine is validated to the minute; use it for the headline times.
            var hours = label == "sunrise" ? sun.riseH : sun.setH
            if label == "sunrise", h >= sun.setH,
               let next = clock.sun(on: s.date.addingTimeInterval(86_400), calendar: calendar) { hours = next.riseH }
            parts.append(String(format: "%@ %02d:%02d", label, Int(hours), Int((hours - Double(Int(hours))) * 60)))
        }
        return parts.joined(separator: " · ")
    }

    static func hourOfDay(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3_600
    }

    /// The next thing worth looking up for, within three hours.
    public static func nextEvent(scene s: SkyScene, weather w: WeatherSnapshot?, clock: SolarClock, calendar: Calendar = .current) -> String? {
        let now = s.date
        let tomorrow = now.addingTimeInterval(86_400)
        var events: [(Date, String)] = []
        for day in [now, tomorrow] {
            if let t = clock.crossing(elevation: -6, rising: true, on: day, calendar: calendar) { events.append((t, "Blue hour")) }
            let start = calendar.startOfDay(for: day)
            let almanac = clock.sun(on: day, calendar: calendar)
            if let a = almanac { events.append((start.addingTimeInterval(a.riseH * 3_600), "Sunrise")) }
            if let t = clock.crossing(elevation: 6, rising: false, on: day, calendar: calendar) { events.append((t, "Golden hour")) }
            if let a = almanac { events.append((start.addingTimeInterval(a.setH * 3_600), "Sunset")) }
            if let t = clock.crossing(elevation: -4, rising: false, on: day, calendar: calendar) { events.append((t, "Blue hour")) }
            if let t = clock.crossing(elevation: -12, rising: false, on: day, calendar: calendar) { events.append((t, "Dark")) }
        }
        var best: (Date, String)?
        for e in events where e.0 > now && e.0.timeIntervalSince(now) < 3 * 3_600 {
            if best == nil || e.0 < best!.0 { best = e }
        }
        // Weather on its way outranks a distant sun event.
        if let w, s.precip == .none, w.precipitationChanceSoon >= 0.6, w.precipitationNearby > 0.2 {
            let what = s.cloudTotal > 0 && w.isSnow ? "Snow" : "Rain"
            if best == nil || best!.0.timeIntervalSince(now) > 45 * 60 {
                return "\(what) likely within two hours"
            }
        }
        guard let (when, name) = best else { return nil }
        let minutes = Int((when.timeIntervalSince(now) / 60).rounded(.up))
        if name == "Dark" { return minutes <= 1 ? "Dark now" : "Dark in \(duration(minutes))" }
        return minutes <= 1 ? "\(name) now" : "\(name) in \(duration(minutes))"
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
