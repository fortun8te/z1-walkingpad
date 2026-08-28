import Foundation

/// Sunrise and sunset, computed locally — no network, no permissions.
///
/// The classic Almanac for Computers algorithm (NOAA), validated against
/// published Amsterdam times to the minute. Location defaults to Amersfoort;
/// the point is honesty of *shape* — dawn at real dawn, long June evenings,
/// dark December afternoons — not GPS precision.
public struct SolarClock: Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double = 52.156, longitude: Double = 5.388) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Local sunrise/sunset as fractional hours (0..<24) for the given date,
    /// or nil in polar day/night.
    public func sun(on date: Date = Date(), calendar: Calendar = .current) -> (riseH: Double, setH: Double)? {
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let tzHours = Double(calendar.timeZone.secondsFromGMT(for: date)) / 3_600
        guard let rise = event(dayOfYear: dayOfYear, rise: true, tzHours: tzHours),
              let set = event(dayOfYear: dayOfYear, rise: false, tzHours: tzHours)
        else { return nil }
        return (rise, set)
    }

    /// Sun position in the sky right now: elevation and azimuth in degrees.
    /// Standard declination/hour-angle formulas — a degree or two of error is
    /// invisible in a gradient.
    public func position(at date: Date = Date(), calendar: Calendar = .current) -> (elevation: Double, azimuth: Double) {
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let localHours = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3_600
        let tzHours = Double(calendar.timeZone.secondsFromGMT(for: date)) / 3_600

        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (localHours - 12) / 24)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let timeOffset = eqTime + 4 * longitude - 60 * tzHours
        let trueSolarMinutes = localHours * 60 + timeOffset
        let hourAngle = (trueSolarMinutes / 4 - 180) * Double.pi / 180
        let latR = latitude * Double.pi / 180

        let sinElev = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(hourAngle)
        let elevation = asin(min(1, max(-1, sinElev))) * 180 / Double.pi

        let cosAz = (sin(decl) - sin(latR) * sinElev)
            / max(0.0001, cos(latR) * cos(asin(min(1, max(-1, sinElev)))))
        var azimuth = acos(min(1, max(-1, cosAz))) * 180 / Double.pi
        if hourAngle > 0 { azimuth = 360 - azimuth }
        return (elevation, azimuth)
    }

    /// Moon elevation and azimuth in degrees. Low-precision Meeus (a degree
    /// or two) — plenty for placing a glow in a 282-pt window.
    public func moonPosition(at date: Date = Date()) -> (elevation: Double, azimuth: Double) {
        let d = date.timeIntervalSince(Date(timeIntervalSince1970: 946_728_000)) / 86_400
        let T = d / 36_525

        func wrap(_ x: Double) -> Double {
            var v = x.truncatingRemainder(dividingBy: 360)
            if v < 0 { v += 360 }
            return v
        }
        func rad(_ deg: Double) -> Double { deg * .pi / 180 }

        let L = wrap(218.3164477 + 13.17639648 * d)
        let M = wrap(134.9633964 + 13.06499295 * d)
        let F = wrap(93.2720950 + 13.22935024 * d)
        let D = wrap(297.8501921 + 12.19074912 * d)
        let Ms = wrap(357.5291092 + 0.98560028 * d)

        let lon = wrap(
            L
            + 6.289 * sin(rad(M))
            + 1.274 * sin(rad(2 * D - M))
            + 0.658 * sin(rad(2 * D))
            + 0.214 * sin(rad(2 * M))
            - 0.186 * sin(rad(Ms))
            - 0.114 * sin(rad(2 * F))
        )
        let lat = 5.128 * sin(rad(F))
            + 0.280 * sin(rad(M + F))
            + 0.277 * sin(rad(F - M))
            + 0.173 * sin(rad(2 * D - F))

        let eps = rad(23.439291 - 0.0130042 * T)
        let lonR = rad(lon)
        let latR = rad(lat)
        let sinDec = sin(latR) * cos(eps) + cos(latR) * sin(eps) * sin(lonR)
        let dec = asin(min(1, max(-1, sinDec)))
        let ra = atan2(
            sin(lonR) * cos(eps) - tan(latR) * sin(eps),
            cos(lonR)
        )

        let lst = wrap(280.46061837 + 360.98564736629 * d + longitude)
        var ha = wrap(lst - ra * 180 / .pi) * .pi / 180
        if ha > .pi { ha -= 2 * .pi }

        let lat0 = latitude * .pi / 180
        let sinElev = sin(lat0) * sin(dec) + cos(lat0) * cos(dec) * cos(ha)
        let elevation = asin(min(1, max(-1, sinElev))) * 180 / .pi
        let cosAz = (sin(dec) - sin(lat0) * sinElev)
            / max(0.0001, cos(lat0) * cos(asin(min(1, max(-1, sinElev)))))
        var azimuth = acos(min(1, max(-1, cosAz))) * 180 / .pi
        if ha > 0 { azimuth = 360 - azimuth }
        return (elevation, azimuth)
    }

    private func event(dayOfYear: Int, rise: Bool, tzHours: Double) -> Double? {
        let lngHour = longitude / 15
        let t = Double(dayOfYear) + ((rise ? 6 : 18) - lngHour) / 24
        let M = 0.9856 * t - 3.289
        var L = M + 1.916 * sin(M * .pi / 180) + 0.020 * sin(2 * M * .pi / 180) + 282.634
        L = L.truncatingRemainder(dividingBy: 360)
        if L < 0 { L += 360 }
        var RA = atan(0.91764 * tan(L * .pi / 180)) * 180 / .pi
        RA = RA.truncatingRemainder(dividingBy: 360)
        if RA < 0 { RA += 360 }
        RA += ((L / 90).rounded(.down) - (RA / 90).rounded(.down)) * 90
        RA /= 15
        let sinDec = 0.39782 * sin(L * .pi / 180)
        let cosDec = cos(asin(sinDec))
        let latR = latitude * .pi / 180
        let cosH = (cos(90.833 * .pi / 180) - sinDec * sin(latR)) / (cosDec * cos(latR))
        guard cosH >= -1, cosH <= 1 else { return nil }
        var H = rise ? 360 - acos(cosH) * 180 / .pi : acos(cosH) * 180 / .pi
        H /= 15
        let T = H + RA - 0.06571 * t - 6.622
        var local = (T - lngHour + tzHours).truncatingRemainder(dividingBy: 24)
        if local < 0 { local += 24 }
        return local
    }
}
