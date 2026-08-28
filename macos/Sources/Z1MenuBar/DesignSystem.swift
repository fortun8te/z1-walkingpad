import SwiftUI
import Z1Core

/// Black, one colour, three greys.
///
/// Blue means one thing only — the belt is moving. Nothing else on screen is
/// allowed to be coloured, because the moment a second hue appears the first
/// one stops meaning anything. Everything else is white at three fixed levels,
/// where the level says how the number was got: full white was measured,
/// half was modelled, and unlit is present but unknown.
enum Z1 {
    static let canvas = Color.black

    static let ink = Color.white
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.26)
    static let unlit = Color.white.opacity(0.06)

    static let hairline = Color.white.opacity(0.11)
    static let hairlineLit = Color.white.opacity(0.30)

    /// The belt is running. The only colour in the app.
    static let live = Color(red: 0.29, green: 0.51, blue: 0.98)

    static let radius: CGFloat = 10
    static let tileRadius: CGFloat = 8
}

/// A card lit from its own edge: colour gathers at the border and falls away
/// to black in the middle. Taken from the reference boards, where the panel
/// glows rather than being filled.
struct AuraCard<Content: View>: View {
    var colour: Color
    var active: Bool
    var radius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    .black,
                                    colour.opacity(active ? 0.62 : 0.14),
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: 118
                            )
                        )
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.clear)
                        .z1InnerGlow(colour, radius: radius, strength: active ? 0.85 : 0.22, width: 14)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    colour.opacity(active ? 0.85 : 0.30),
                                    colour.opacity(active ? 0.25 : 0.06),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                }
                .shadow(color: colour.opacity(active ? 0.45 : 0.10), radius: 20)
                .animation(.smooth(duration: 0.45), value: active)
            }
    }
}

extension View {
    /// Light pooling inside the bottom edge of a card, the way a screen glows
    /// against its own bezel. Built as a blurred stroke masked to the shape —
    /// SwiftUI has no inner shadow, and a drop shadow puts the light outside
    /// the card, which reads as a halo instead of as depth.
    func z1InnerGlow(
        _ colour: Color,
        radius: CGFloat,
        strength: Double,
        width: CGFloat = 11
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.25),
                            .init(color: colour.opacity(strength * 0.45), location: 0.72),
                            .init(color: colour.opacity(strength), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: width
                )
                .blur(radius: width * 0.62)
                .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)
        )
    }

    /// A surface defined by its edge, not its fill.
    func z1Card(radius: CGFloat = Z1.radius, lit: Bool = false) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(lit ? Z1.hairlineLit : Z1.hairline, lineWidth: 0.7)
        )
    }
}

/// Flat, edge-drawn, sentence case. No tracking, no rounded face, no caps —
/// those three together are what makes an interface look generated.
struct HairlineButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Z1Type.regular(11))
            .foregroundStyle(Z1.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.26 : 0.13), lineWidth: 0.7)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onHover { hovering = $0 }
    }
}


/// The window's ground: the sky outside, right now.
///
/// The horizon colour tracks local time — amber at dawn, blue through the day,
/// orange at dusk, deep indigo at night — while the top of the window stays
/// near-black so the interface on top of it never stops being readable. Stars
/// fade in as the light goes, and occasionally one falls.
///
/// **On battery:** a `MenuBarExtra` only renders its content while the popover
/// is open, so none of this animates when you are not looking at it. The app's
/// idle cost is unchanged.
struct SkyField: View {
    /// The belt-running blue is the only UI accent. Sky colour stays on the
    /// background; it is not mixed into controls.
    static func accent(at date: Date = Date(), weather: WeatherSnapshot?) -> Color {
        let _ = (date, weather)
        return Z1.live
    }

    /// 0…1 — how far into the day's goal. Feeds the horizon's extra warmth.
    var intensity: Double
    /// Injectable for previews and tests; defaults to now.
    var date: Date = Date()
    /// Live conditions outside; nil renders a clear sky.
    var weather: WeatherSnapshot?
    /// Planetary K-index; ≥6.5 on a clear night paints the aurora.
    var kp: Double = 0

    @State private var shooting = false
    @State private var shootSeed = 0

    // MARK: - simulator (hidden)
    //
    // `defaults write dev.z1walkingpad.menubar z1.skySimHour -float 20.75`
    // `defaults write dev.z1walkingpad.menubar z1.skySimWeather clear|overcast|rain|snow`
    // Render any hour and any weather on demand — the only honest way to
    // verify a dawn without setting an alarm. Delete the keys to return to
    // reality.

    private var effectiveWeather: WeatherSnapshot? {
        switch UserDefaults.standard.string(forKey: "z1.skySimWeather") {
        case "clear":
            return WeatherSnapshot(cloudCover: 0.05, precipitation: 0, weatherCode: 0, fetchedAt: date)
        case "overcast":
            return WeatherSnapshot(cloudCover: 0.95, precipitation: 0, weatherCode: 3, fetchedAt: date)
        case "rain":
            return WeatherSnapshot(cloudCover: 0.85, precipitation: 1.4, weatherCode: 61, fetchedAt: date)
        case "snow":
            return WeatherSnapshot(cloudCover: 0.85, precipitation: 1.0, weatherCode: 71, fetchedAt: date)
        case "partly":
            return WeatherSnapshot(cloudCover: 0.45, precipitation: 0, weatherCode: 2, fetchedAt: date)
        case "fog":
            return WeatherSnapshot(cloudCover: 0.7, precipitation: 0, weatherCode: 45, fetchedAt: date)
        case "storm":
            return WeatherSnapshot(cloudCover: 0.9, precipitation: 2.5, weatherCode: 95, windSpeed: 38, fetchedAt: date)
        case "sunshower":
            return WeatherSnapshot(cloudCover: 0.35, precipitation: 0.5, weatherCode: 61, fetchedAt: date)
        case "downpour":
            return WeatherSnapshot(cloudCover: 0.9, precipitation: 3.0, weatherCode: 65, windSpeed: 30, fetchedAt: date)
        case "windy":
            return WeatherSnapshot(cloudCover: 0.2, precipitation: 0, weatherCode: 1, windSpeed: 34, fetchedAt: date)
        default:
            return weather
        }
    }

    private var isFog: Bool { [45, 48].contains(effectiveWeather?.weatherCode ?? -1) }
    private var isStorm: Bool { (95...99).contains(effectiveWeather?.weatherCode ?? -1) }

    private var cloud: Double { effectiveWeather?.cloudCover ?? 0 }
    private var effectiveKp: Double {
        let sim = UserDefaults.standard.double(forKey: "z1.skySimKp")
        return sim > 0 ? sim : kp
    }
    /// Stars and moon survive scattered cloud, vanish under a closed deck.
    private var clearness: Double { 1 - 0.85 * cloud }

    // MARK: - the palette, keyed to where the sun actually is

    private struct Sky {
        var zenith: Color      // top of the window — always nearly black
        var mid: Color         // the body of the field
        var horizon: Color     // the bottom edge
        var glow: Color        // the pale core the light comes from
        var stars: Double
    }

    /// Solar elevation in degrees drives everything: the same physics that
    /// makes June evenings long makes this window amber at 20:45 in August
    /// and dark at 17:00 in December.
    private func sky(at date: Date) -> Sky {
        let e = SolarClock().position(at: date).elevation
        let bands: [(Double, Sky)] = [
            (-18, Sky(zenith: .black,
                      mid: Color(red: 0.015, green: 0.02, blue: 0.08),
                      horizon: Color(red: 0.04, green: 0.06, blue: 0.18),
                      glow: Color(red: 0.22, green: 0.32, blue: 0.70), stars: 1.0)),
            (-12, Sky(zenith: .black,
                      mid: Color(red: 0.03, green: 0.03, blue: 0.14),
                      horizon: Color(red: 0.12, green: 0.08, blue: 0.34),
                      glow: Color(red: 0.42, green: 0.28, blue: 0.78), stars: 0.88)),
            (-6, Sky(zenith: .black,
                     mid: Color(red: 0.09, green: 0.04, blue: 0.20),
                     horizon: Color(red: 0.62, green: 0.16, blue: 0.28),
                     glow: Color(red: 0.96, green: 0.38, blue: 0.32), stars: 0.48)),
            (-1, Sky(zenith: Color(red: 0.02, green: 0.02, blue: 0.10),
                     mid: Color(red: 0.20, green: 0.07, blue: 0.22),
                     horizon: Color(red: 0.98, green: 0.36, blue: 0.14),
                     glow: Color(red: 1.00, green: 0.68, blue: 0.36), stars: 0.14)),
            (5, Sky(zenith: Color(red: 0.02, green: 0.04, blue: 0.13),
                    mid: Color(red: 0.18, green: 0.18, blue: 0.42),
                    horizon: Color(red: 1.00, green: 0.58, blue: 0.26),
                    glow: Color(red: 1.00, green: 0.82, blue: 0.52), stars: 0.0)),
            (14, Sky(zenith: Color(red: 0.01, green: 0.05, blue: 0.16),
                     mid: Color(red: 0.12, green: 0.32, blue: 0.64),
                     horizon: Color(red: 0.58, green: 0.70, blue: 0.92),
                     glow: Color(red: 0.90, green: 0.88, blue: 0.78), stars: 0.0)),
            (28, Sky(zenith: Color(red: 0.02, green: 0.07, blue: 0.20),
                     mid: Color(red: 0.14, green: 0.40, blue: 0.80),
                     horizon: Color(red: 0.42, green: 0.72, blue: 1.00),
                     glow: Color(red: 0.82, green: 0.93, blue: 1.00), stars: 0.0)),
            (55, Sky(zenith: Color(red: 0.03, green: 0.10, blue: 0.26),
                     mid: Color(red: 0.16, green: 0.48, blue: 0.90),
                     horizon: Color(red: 0.52, green: 0.80, blue: 1.00),
                     glow: Color(red: 0.88, green: 0.96, blue: 1.00), stars: 0.0)),
        ]
        var lower = bands[0]
        var upper = bands[bands.count - 1]
        for i in 0..<(bands.count - 1) where e >= bands[i].0 && e <= bands[i + 1].0 {
            lower = bands[i]; upper = bands[i + 1]; break
        }
        if e < bands[0].0 { return grade(bands[0].1, elevation: e, at: date) }
        if e > bands[bands.count - 1].0 { return grade(bands[bands.count - 1].1, elevation: e, at: date) }
        let t = (e - lower.0) / max(0.0001, upper.0 - lower.0)
        let blended = Sky(
            zenith: blend(lower.1.zenith, upper.1.zenith, t),
            mid: blend(lower.1.mid, upper.1.mid, t),
            horizon: blend(lower.1.horizon, upper.1.horizon, t),
            glow: blend(lower.1.glow, upper.1.glow, t),
            stars: lower.1.stars + (upper.1.stars - lower.1.stars) * t
        )
        return grade(blended, elevation: e, at: date)
    }

    /// Season, day-character, and weather — the sky itself changes, not a veil.
    private func grade(_ sky: Sky, elevation e: Double, at date: Date) -> Sky {
        var result = sky
        let lowSun = max(0, 1 - abs(e) / 10)
        if lowSun > 0 {
            let character = dayCharacter(at: date)
            result.horizon = shifted(result.horizon, hue: character.hueDrift * lowSun, sat: (character.vividness - 1) * lowSun * 0.55)
            result.glow = shifted(result.glow, hue: character.hueDrift * lowSun, sat: (character.vividness - 1) * lowSun * 0.45)
            result.mid = shifted(result.mid, hue: character.hueDrift * lowSun * 0.4, sat: 0.06 * lowSun)
        }

        let cover = cloud
        if lowSun > 0, cover > 0.12, cover < 0.70 {
            let boost = lowSun * max(0, 1 - abs(cover - 0.38) / 0.28)
            if boost > 0 {
                result.horizon = shifted(result.horizon, hue: -0.04 * boost, sat: 0.18 * boost, bri: 0.06 * boost)
                result.mid = blend(result.mid, shifted(result.horizon, hue: 0.02), 0.28 * boost)
            }
        }

        let warmth = seasonWarmth(at: date)
        result.mid = shifted(result.mid, hue: -warmth * 0.022)
        result.zenith = shifted(result.zenith, hue: -warmth * 0.018)
        if e > 18, warmth > 0 {
            result.mid = shifted(result.mid, hue: 0, bri: 0.06 * warmth)
            result.horizon = shifted(result.horizon, hue: 0, bri: 0.05 * warmth)
        } else if e > 8, warmth < 0 {
            result.mid = shifted(result.mid, hue: 0.01, sat: -0.06 * -warmth, bri: -0.03 * -warmth)
        }

        // Closed cloud becomes the sky: flatten, desaturate, lift the top.
        if cover > 0.18 {
            let w = cover * cover
            let slab: Color
            if isStorm {
                slab = Color(red: 0.14, green: 0.18, blue: 0.20)
            } else if effectiveWeather?.isSnow == true {
                slab = Color(red: 0.52, green: 0.58, blue: 0.66)
            } else if effectiveWeather?.isRaining == true {
                slab = Color(red: 0.20, green: 0.24, blue: 0.30)
            } else {
                slab = Color(red: 0.30, green: 0.34, blue: 0.40)
            }
            result.mid = blend(result.mid, slab, 0.62 * w)
            result.horizon = blend(result.horizon, shifted(slab, hue: 0, bri: 0.10), 0.55 * w)
            result.zenith = blend(result.zenith, shifted(slab, hue: 0, bri: -0.16), 0.42 * w)
            result.glow = blend(result.glow, slab, 0.58 * w)
            result.stars *= (1 - 0.92 * cover)
        }

        if isFog {
            let milk = Color(red: 0.64, green: 0.66, blue: 0.68)
            result.horizon = blend(result.horizon, milk, 0.72)
            result.mid = blend(result.mid, milk, 0.62)
            result.zenith = blend(result.zenith, milk, 0.40)
            result.glow = blend(result.glow, milk, 0.75)
            result.stars *= 0.15
        }
        if isStorm {
            let slate = Color(red: 0.12, green: 0.18, blue: 0.16)
            result.horizon = blend(result.horizon, slate, 0.55)
            result.mid = blend(result.mid, slate, 0.50)
            result.glow = blend(result.glow, slate, 0.45)
        }
        if effectiveWeather?.isSnow == true {
            result.horizon = shifted(result.horizon, hue: 0.03, sat: -0.18, bri: 0.12)
            result.mid = shifted(result.mid, hue: 0.01, sat: -0.12, bri: 0.08)
            result.glow = shifted(result.glow, hue: 0, sat: -0.10, bri: 0.06)
        }
        if effectiveWeather?.isRaining == true, !isStorm {
            result.mid = shifted(result.mid, hue: 0.02, sat: -0.04, bri: -0.08)
            result.horizon = shifted(result.horizon, hue: 0.015, sat: -0.06, bri: -0.06)
        }

        if result.stars > 0.5 {
            let moonlight = MoonPhase.illumination(at: date) * clearness * result.stars
            if moonlight > 0.1 {
                let silver = Color(red: 0.70, green: 0.76, blue: 0.88)
                result.mid = blend(result.mid, silver, 0.12 * moonlight)
                result.horizon = blend(result.horizon, silver, 0.14 * moonlight)
            }
        }
        return result
    }

    /// Shift a colour in HSB space — the honest way to turn an orange sunset
    /// rose or violet without inventing a new palette.
    private func shifted(_ c: Color, hue dH: Double, sat dS: Double = 0, bri dB: Double = 0) -> Color {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        var nh = (h + dH).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return Color(
            hue: nh,
            saturation: min(1, max(0, sat + dS)),
            brightness: min(1, max(0, b + dB))
        )
    }

    /// Every date gets a character, seeded from the calendar day: some
    /// evenings burn orange, some go rose, some violet — deterministic, so
    /// the sky does not change its mind between glances.
    private func dayCharacter(at date: Date) -> (hueDrift: Double, vividness: Double) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var seed = UInt64((parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0))
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let r1 = Double((seed >> 33) & 0xFFFF) / 65_535
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let r2 = Double((seed >> 33) & 0xFFFF) / 65_535
        // hueDrift: -0.10 (crimson, rose, violet) … +0.08 (peach gold)
        return (r1 * 0.18 - 0.10, 0.82 + r2 * 0.45)
    }

    /// Warm in high summer, cold in deep winter — a small temperature slide
    /// across the year, applied to the blues.
    private func seasonWarmth(at date: Date) -> Double {
        let dayOfYear = Double(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 182)
        return sin((dayOfYear - 172) / 365 * 2 * .pi + .pi / 2) // 1 midsummer, -1 midwinter
    }

    /// South-facing window: east is left, west is right. Elevation 0 sits
    /// near the bottom; a high sun leaves the frame and becomes the blue.
    private func project(azimuth: Double, elevation: Double) -> (x: Double, y: Double) {
        (
            (azimuth - 90) / 180 * 0.84 + 0.08,
            0.93 - elevation * (0.78 / 24)
        )
    }

    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .black
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .black
        return Color(
            red: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t
        )
    }

    // MARK: - body

    var body: some View {
        // Static sky. A 10 Hz TimelineView here lived in the MenuBarExtra
        // window even when closed and melted the status item.
        let now = Date()
        skyContent(motionAt: now, skyAt: resolvedDate(now: now))
            .animation(.smooth(duration: 0.9), value: intensity)
    }

    /// Simulator freezes the hour for the sun; live time still drives drift.
    private func resolvedDate(now: Date) -> Date {
        var base = date
        if let simDay = UserDefaults.standard.string(forKey: "z1.skySimDate") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: simDay) { base = parsed }
        }
        let simHour = UserDefaults.standard.double(forKey: "z1.skySimHour")
        guard simHour > 0 || UserDefaults.standard.string(forKey: "z1.skySimDate") != nil else { return now }
        let start = Calendar.current.startOfDay(for: base)
        return start.addingTimeInterval((simHour > 0 ? simHour : 12) * 3_600)
    }

    private func skyContent(motionAt: Date, skyAt: Date) -> some View {
        let palette = sky(at: skyAt)
        let w = effectiveWeather
        let sun = SolarClock().position(at: skyAt)
        let moonPos = SolarClock().moonPosition(at: skyAt)
        let pressure = w?.pressure ?? 1_013
        let mute = (1 - 0.18 * cloud) * (1 - min(0.10, max(0, (1_010 - pressure) / 250)))
        let sunXY = project(azimuth: sun.azimuth, elevation: sun.elevation)
        let moonXY = project(azimuth: moonPos.azimuth, elevation: moonPos.elevation)
        let air = max(0, 1 - cloud * 1.05)
        let sunInFrame = sun.elevation > -3 && sun.elevation < 22
            && sunXY.y > 0.02 && sunXY.y < 1.08
            && sunXY.x > -0.05 && sunXY.x < 1.05
        let sunInfluences = sun.elevation > -8
        let flare = sunInFrame && cloud < 0.38 && (w?.precipStyle ?? .none) == WeatherSnapshot.PrecipStyle.none
        let lowSun = max(0, 1 - abs(sun.elevation) / 10)
        let month = Calendar.current.component(.month, from: skyAt)
        let cloudBody = blend(Color(red: 0.93, green: 0.94, blue: 0.96), palette.mid, 0.22 + 0.28 * cloud)
        let cloudUnder: Color = sun.elevation < 9 && sun.elevation > -4
            ? blend(palette.glow, palette.horizon, 0.35)
            : blend(palette.mid, Color(red: 0.22, green: 0.24, blue: 0.28), 0.45)
        let cloudLit: Color = sun.elevation < 9
            ? blend(.white, palette.glow, 0.35)
            : Color.white
        return GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let fromBottom: (CGFloat) -> CGFloat = { max(0, 1 - $0 / height) }
            ZStack {
            Color.black

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.00),
                    .init(color: palette.zenith.opacity(0.92 * mute), location: fromBottom(300)),
                    .init(color: palette.mid.opacity(0.78 * mute), location: fromBottom(180)),
                    .init(color: palette.mid.opacity(0.96 * mute), location: fromBottom(95)),
                    .init(color: palette.horizon.opacity(0.94 * mute), location: fromBottom(30)),
                    .init(color: palette.glow.opacity(0.62 * mute), location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if sunInfluences {
                sunLight(
                    x: sunInFrame ? sunXY.x : min(0.92, max(0.08, sunXY.x)),
                    y: sunInFrame ? sunXY.y : max(-0.05, min(0.12, sunXY.y)),
                    sky: palette,
                    air: air,
                    inFrame: sunInFrame
                )
            }

            if flare {
                SkyLayers.LensFlare(
                    sunX: sunXY.x,
                    sunY: sunXY.y,
                    strength: air * (1 - min(1, max(0, sun.elevation) / 18)) * (0.65 + 0.35 * lowSun),
                    tint: palette.glow
                )
            }

            if sunInFrame, cloud > 0.15, cloud < 0.7 {
                SkyLayers.GodRays(
                    sunX: sunXY.x,
                    sunY: sunXY.y,
                    strength: (1 - abs(cloud - 0.4) / 0.3) * max(0, 1 - sun.elevation / 14) * air,
                    tint: palette.glow
                )
            }

            RadialGradient(
                stops: [
                    .init(color: palette.glow.opacity((0.15 + 0.40 * min(intensity, 1)) * mute), location: 0),
                    .init(color: .clear, location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0,
                endRadius: 190
            )
            .blendMode(.screen)

            stars(palette.stars * clearness)
            moonLight(
                x: moonXY.x, y: moonXY.y,
                elevation: moonPos.elevation,
                at: skyAt,
                stars: palette.stars,
                clearness: clearness
            )

            if effectiveKp >= 6.5, palette.stars * clearness > 0.5 {
                SkyLayers.Aurora(
                    strength: min(1, (effectiveKp - 6) / 3),
                    now: motionAt
                )
            }

            SkyLayers.Clouds(
                cover: cloud,
                windKmh: w?.windSpeed ?? 8,
                windDirection: w?.windDirection ?? 230,
                body_: cloudBody,
                underside: cloudUnder,
                highlight: cloudLit,
                lightX: sunInFrame ? sunXY.x : 0.5,
                now: motionAt
            )

            if w?.isFoggy == true {
                SkyLayers.Mist(
                    strength: min(1, max(0.4, 1 - (w?.visibility ?? 0) / 4_000)),
                    tint: Color(red: 0.62, green: 0.64, blue: 0.66)
                )
            }

            if let w, w.precipStyle != .none {
                SkyLayers.Precipitation(
                    style: w.precipStyle,
                    windKmh: w.windSpeed,
                    windDirection: w.windDirection,
                    now: motionAt
                )
            }

            if let w, [.drizzle, .rain].contains(w.precipStyle),
               sun.elevation > 1, sun.elevation < 40, cloud < 0.85 {
                SkyLayers.Rainbow(
                    antiSolarX: 1 - sunXY.x,
                    strength: air * min(1, sun.elevation / 10)
                )
            }

            SkyLayers.WindDrift(
                windKmh: w?.windSpeed ?? 0,
                windDirection: w?.windDirection ?? 230,
                month: month,
                dry: (w?.precipStyle ?? .none) == WeatherSnapshot.PrecipStyle.none,
                now: motionAt
            )

            if effectiveWeather?.isThunderstorm == true {
                SkyLayers.Lightning(now: motionAt)
            }

            SkyLayers.Grain(
                warmth: max(0, 1 - abs(sun.elevation) / 12),
                amount: 0.9
            )
            }
        }
    }

    /// Sun as a light, not a sticker: a large atmospheric bloom and a small
    /// hot core with no hard edge. High sun is a wash from above.
    private func sunLight(x: Double, y: Double, sky: Sky, air: Double, inFrame: Bool) -> some View {
        let core = inFrame ? air : air * 0.35
        return ZStack {
            RadialGradient(
                colors: [
                    sky.glow.opacity(0.58 * air),
                    sky.horizon.opacity(0.22 * air),
                    .clear,
                ],
                center: UnitPoint(x: x, y: y),
                startRadius: 4,
                endRadius: inFrame ? 170 : 220
            )
            .blendMode(.screen)
            RadialGradient(
                colors: [
                    Color.white.opacity(0.72 * core),
                    sky.glow.opacity(0.38 * core),
                    .clear,
                ],
                center: UnitPoint(x: x, y: y),
                startRadius: 0,
                endRadius: inFrame ? 20 : 36
            )
            .blendMode(.screen)
        }
        .allowsHitTesting(false)
    }

    /// Moon as a light source at its real azimuth/elevation. Soft bloom plus
    /// a phase-lit disc with earthshine — no cookie-cutter shadow, no pin.
    private func moonLight(
        x: Double, y: Double,
        elevation: Double,
        at date: Date,
        stars: Double,
        clearness: Double
    ) -> some View {
        let illum = MoonPhase.illumination(at: date)
        let phase = MoonPhase.fraction(at: date)
        let show = elevation > -1 && stars * clearness > 0.28 && illum > 0.04
            && y > -0.08 && y < 1.08
        return Canvas { context, size in
            guard show else { return }
            let cx = x * size.width
            let cy = y * size.height
            let r: CGFloat = 11
            let silver = Color(red: 0.78, green: 0.84, blue: 0.96)
            var bloom = context
            bloom.addFilter(.blur(radius: 14))
            bloom.opacity = 0.28 * illum * clearness
            bloom.fill(
                Path(ellipseIn: CGRect(x: cx - 36, y: cy - 36, width: 72, height: 72)),
                with: .color(silver)
            )
            let disc = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            var earth = context
            earth.addFilter(.blur(radius: 0.7))
            earth.opacity = 0.14 * clearness
            earth.fill(Path(ellipseIn: disc), with: .color(Color(red: 0.40, green: 0.48, blue: 0.62)))
            let dir: CGFloat = phase < 0.5 ? 1 : -1
            let lit = Color(red: 0.90, green: 0.92, blue: 0.97)
            var limb = context
            limb.addFilter(.blur(radius: 0.9))
            limb.opacity = (0.40 + 0.50 * illum) * clearness
            limb.fill(
                Path(ellipseIn: disc),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: lit.opacity(0.05 + 0.10 * illum), location: 0),
                        .init(color: lit.opacity(0.45 + 0.50 * illum), location: CGFloat(min(0.9, max(0.1, illum)))),
                        .init(color: lit.opacity(0.92), location: 1),
                    ]),
                    startPoint: CGPoint(x: cx - r * dir, y: cy),
                    endPoint: CGPoint(x: cx + r * dir, y: cy)
                )
            )
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    /// Fixed-seed field, so the sky is the same sky every time you open it and
    /// the specks never crawl between redraws.
    private func stars(_ alpha: Double) -> some View {
        Canvas { context, size in
            guard alpha > 0.01 else { return }
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
            }
            for _ in 0..<300 {
                let x = next() * size.width
                let y = next() * size.height
                let depth = y / max(size.height, 1)
                // Thin out toward the horizon, the way the glow washes them out.
                let a = (0.06 + next() * 0.34) * alpha * (1.0 - depth * 0.75)
                let r = 0.7 + next() * 0.7
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(.white.opacity(a))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var fallingStar: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let start = CGPoint(
                x: w * (0.15 + Double(shootSeed % 5) * 0.16),
                y: 14 + Double(shootSeed % 3) * 24
            )
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 46, height: 1.4)
                .rotationEffect(.degrees(28))
                .position(x: start.x, y: start.y)
                // Travels on a linear path while its brightness rises and dies
                // (the keyframes below) — visible for well under a second, the
                // way a real one is gone before you are sure you saw it.
                .offset(x: shooting ? 110 : -24, y: shooting ? 58 : -13)
                .animation(.easeIn(duration: 0.9), value: shooting)
                .keyframeAnimator(
                    initialValue: 0.0,
                    trigger: shootSeed
                ) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(0.0, duration: 0.05)
                        CubicKeyframe(0.9, duration: 0.25)
                        CubicKeyframe(0.7, duration: 0.35)
                        CubicKeyframe(0.0, duration: 0.30)
                    }
                }
                .allowsHitTesting(false)
        }
    }

    private func scheduleStar() {
        guard sky(at: resolvedDate(now: Date())).stars > 0.3 else { return }
        // First one soon after the window opens — a rare event nobody ever
        // sees is indistinguishable from a feature that does not exist (it
        // was, in fact, exactly that: an opacity bug kept every star at 0).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { fireStar() }
        Timer.scheduledTimer(withTimeInterval: 23, repeats: true) { _ in fireStar() }
    }

    private func fireStar() {
        shootSeed &+= 1
        shooting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { shooting = false }
    }
}

/// The window's ground: black at the top falling into blue at the bottom edge,
/// with a fine grain over it.
///
/// The grain matters more than it sounds. A pure SwiftUI gradient across 450
/// points banded visibly on a dark field — flat stripes where the blue steps.
/// Scattering a few hundred faint specks breaks the banding up the way film
/// grain does, and it is drawn once from a fixed seed so it never shimmers
/// between redraws.
struct NightField: View {
    /// 0…1 — how far into the day's goal. Never fully dark, so the window
    /// always has its floor.
    var intensity: Double

    private var lift: Double { 0.38 + 0.62 * min(max(intensity, 0), 1) }

    /// The pale core the light appears to come *from*. A vertical ramp alone
    /// reads as a painted wash; light reads as light only when it has a hot
    /// spot and falls off in two directions at once.
    private var core: Color { Color(red: 0.62, green: 0.80, blue: 1.0) }

    var body: some View {
        ZStack {
            Color.black

            // Vertical ramp: black held long at the top so the hero card keeps
            // its separation, then a fast climb over the last third.
            LinearGradient(
                // Held black much longer than looks natural in isolation.
                // Text sits over the middle of this window, and grey-on-blue
                // was unreadable — the light has to live below the words.
                stops: [
                    .init(color: .black, location: 0.00),
                    .init(color: .black, location: 0.55),
                    .init(color: Z1.live.opacity(0.10 * lift), location: 0.72),
                    .init(color: Z1.live.opacity(0.34 * lift), location: 0.86),
                    .init(color: Z1.live.opacity(0.70 * lift), location: 0.95),
                    .init(color: core.opacity(0.60 * lift), location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // The hot spot, sitting just past the bottom edge and narrower than
            // the window, so the bottom corners stay dark and the middle glows.
            RadialGradient(
                stops: [
                    .init(color: core.opacity(0.50 * lift), location: 0.00),
                    .init(color: Z1.live.opacity(0.26 * lift), location: 0.40),
                    .init(color: .clear, location: 1.00),
                ],
                center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0,
                endRadius: 170
            )
            .blendMode(.screen)

            grain
        }
        .animation(.smooth(duration: 0.9), value: intensity)
    }

    private var grain: some View {
        Canvas { context, size in
            // Fixed-seed LCG: deterministic, so the speckle is part of the
            // design rather than noise that dances on every state change.
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
            }
            for _ in 0..<340 {
                let x = next() * size.width
                let y = next() * size.height
                // Denser and brighter toward the lit end, like the reference.
                let depth = y / max(size.height, 1)
                let alpha = (0.04 + next() * 0.10) * (0.30 + depth)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 0.9, height: 0.9)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }
}


extension View {
    /// Real Liquid Glass where the OS has it, a material veil where it
    /// does not. Cards sit on the living sky, so the backdrop always gives
    /// the glass something to bend.
    @ViewBuilder
    func z1LiquidGlass(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.30)
            )
        }
    }
}
