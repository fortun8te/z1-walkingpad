import SwiftUI
import Z1Core

/// The sky's moving parts, each a small self-contained layer. Motion layers
/// used by `SkyField` take a shared `now` so the popover has one clock —
/// nested TimelineViews at mismatched rates were the flicker.
enum SkyLayers {

    // MARK: - clouds

    /// Seeded cumulus clusters: overlapping puffs with a shaded base, a lit
    /// crown, and a sunset-pink belly when the sun is low. Drift is wind-driven
    /// and wraps fully off-screen (plus a pad) so nothing teleports in view.
    /// Cover fades slots in rather than jumping the count.
    struct Clouds: View {
        var cover: Double
        var windKmh: Double
        var windDirection: Double
        var body_: Color
        var underside: Color
        var highlight: Color
        var lightX: Double
        var now: Date

        private struct Puff { var dx: Double; var dy: Double; var w: Double; var h: Double }

        private static func puffs(seed: Int) -> [Puff] {
            var rng = UInt64(seed &* 7_919 &+ 104_729)
            func next() -> Double {
                rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((rng >> 33) & 0xFFFF) / 65_535
            }
            // Flat base + stacked crown — a readable silhouette at 282 pt.
            var result: [Puff] = [
                Puff(dx: 0.00, dy: 0.32, w: 1.00, h: 0.50),
                Puff(dx: -0.26, dy: 0.12, w: 0.54, h: 0.56),
                Puff(dx: 0.24, dy: 0.08, w: 0.58, h: 0.58),
                Puff(dx: -0.02, dy: -0.14, w: 0.46, h: 0.52),
            ]
            for _ in 0..<(1 + Int(next() * 2)) {
                result.append(Puff(
                    dx: next() * 0.72 - 0.36,
                    dy: next() * 0.30 - 0.16,
                    w: 0.30 + next() * 0.30,
                    h: 0.32 + next() * 0.24
                ))
            }
            return result
        }

        var body: some View {
            Canvas { context, size in
                guard cover > 0.04 else { return }
                let t = now.timeIntervalSinceReferenceDate
                let east = -sin(windDirection * .pi / 180)
                let sign = east >= 0 ? max(0.22, east) : min(-0.22, east)
                let deck = max(0, (cover - 0.55) / 0.45)
                let slots = 7
                for i in 0..<slots {
                    let fi = Double(i)
                    let appear = smooth(
                        from: fi * 0.11,
                        to: fi * 0.11 + 0.16,
                        cover
                    )
                    guard appear > 0.02 else { continue }

                    let w = size.width * (0.38 + 0.34 * deck)
                        * (0.82 + fi.truncatingRemainder(dividingBy: 3) * 0.12)
                    let h = size.height * (0.085 + 0.045 * deck)
                    let pad = w + 28
                    let travel = Double(size.width) + pad * 2
                    let depth = 0.62 + fi.truncatingRemainder(dividingBy: 3) * 0.22
                    let speed = (8 + windKmh * 0.55) * depth
                    var x = (t * speed * sign + fi * 331).truncatingRemainder(dividingBy: travel)
                    if x < 0 { x += travel }
                    x -= pad
                    let y = size.height * (0.05 + 0.36 * ((fi * 0.37).truncatingRemainder(dividingBy: 1)))
                    let alpha = appear * (0.58 + 0.22 * cover)
                    drawCloud(
                        context: &context,
                        x: x, y: y, w: w, h: h,
                        seed: i,
                        alpha: alpha,
                        deck: deck
                    )
                }
            }
            .allowsHitTesting(false)
        }

        private func drawCloud(
            context: inout GraphicsContext,
            x: Double, y: Double, w: Double, h: Double,
            seed: Int, alpha: Double, deck: Double
        ) {
            let puffs = Self.puffs(seed: seed)
            let lit = (lightX - 0.5) * 0.18
            let blur = 1.4 + deck * 1.6

            // Underside first — a single shaded belly, pink at a low sun.
            var belly = context
            belly.addFilter(.blur(radius: blur + 0.6))
            belly.opacity = alpha * 0.92
            belly.fill(
                Path(ellipseIn: CGRect(
                    x: x + w * 0.04, y: y + h * 0.52,
                    width: w * 0.92, height: h * 0.62
                )),
                with: .color(underside)
            )

            for puff in puffs {
                let rect = CGRect(
                    x: x + puff.dx * w,
                    y: y + puff.dy * h * 2,
                    width: w * puff.w,
                    height: h * puff.h * 2
                )
                var body = context
                body.addFilter(.blur(radius: blur))
                body.opacity = alpha
                body.fill(Path(ellipseIn: rect), with: .color(body_))
            }

            // Lit crown: smaller puffs on the sunward, upper side.
            for puff in puffs where puff.dy < 0.18 {
                let hw = w * puff.w * 0.55
                let hh = h * puff.h * 0.9
                let rect = CGRect(
                    x: x + puff.dx * w + w * puff.w * 0.22 + lit * w,
                    y: y + puff.dy * h * 2 - h * 0.04,
                    width: hw,
                    height: hh
                )
                var crown = context
                crown.addFilter(.blur(radius: blur * 0.8))
                crown.opacity = alpha * 0.55
                crown.fill(Path(ellipseIn: rect), with: .color(highlight))
            }
        }

        private func smooth(from a: Double, to b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - a) / max(0.0001, b - a)))
            return t * t * (3 - 2 * t)
        }
    }

    // MARK: - typed precipitation

    /// Drizzle is not a downpour: count, speed, length, slant and weight all
    /// come from the reported style, and the wind leans the whole curtain.
    struct Precipitation: View {
        var style: WeatherSnapshot.PrecipStyle
        var windKmh: Double
        var windDirection: Double
        var now: Date

        private var spec: (count: Int, speed: Double, length: Double, alpha: Double, width: Double)? {
            switch style {
            case .none: return nil
            case .drizzle: return (22, 42, 6, 0.22, 0.6)
            case .rain: return (34, 88, 11, 0.32, 0.8)
            case .downpour: return (52, 130, 16, 0.42, 1.1)
            case .flurry: return (24, 10, 0, 0.42, 0)
            case .snow: return (40, 14, 0, 0.52, 0)
            case .heavySnow: return (64, 20, 0, 0.62, 0)
            }
        }

        var body: some View {
            if let spec {
                Canvas { context, size in
                    let t = now.timeIntervalSinceReferenceDate
                    let slantSign: Double = -sin(windDirection * .pi / 180)
                    let slant = min(0.45, windKmh / 60) * slantSign
                    let snow = spec.length == 0
                    let fall = Double(size.height) + 48
                    for i in 0..<spec.count {
                        let fi = Double(i)
                        let speed = spec.speed * (0.8 + fi.truncatingRemainder(dividingBy: 5) * 0.1)
                        let x0 = (fi * 61.7).truncatingRemainder(dividingBy: Double(size.width))
                        var drop = (t * speed + fi * 137).truncatingRemainder(dividingBy: fall)
                        if drop < 0 { drop += fall }
                        drop -= 24
                        if snow {
                            let sway = sin(t * 0.8 + fi) * (6 + windKmh * 0.3)
                            let r = 1.2 + fi.truncatingRemainder(dividingBy: 3) * 0.7
                            context.fill(
                                Path(ellipseIn: CGRect(
                                    x: x0 + sway + drop * slant * 0.6, y: drop, width: r, height: r
                                )),
                                with: .color(.white.opacity(spec.alpha))
                            )
                        } else {
                            var path = Path()
                            let x = x0 + drop * slant * 0.3
                            path.move(to: CGPoint(x: x, y: drop))
                            path.addLine(to: CGPoint(
                                x: x + spec.length * slant + 1.5, y: drop + spec.length
                            ))
                            context.stroke(
                                path,
                                with: .color(.white.opacity(spec.alpha)),
                                lineWidth: spec.width
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - splash on the interface

    /// Apple-Weather style: the rain lands ON the interface. A thin strip
    /// meant to overlay a card's top edge — drops die against it in small
    /// short-lived crowns.
    struct RainSplash: View {
        var style: WeatherSnapshot.PrecipStyle

        private var rate: Int? {
            switch style {
            case .drizzle: 5
            case .rain: 10
            case .downpour: 20
            default: nil
            }
        }

        var body: some View {
            if let rate {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { timeline in
                    Canvas { context, size in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        for i in 0..<rate {
                            let fi = Double(i)
                            let phase = (t * 2 + fi * 0.37).truncatingRemainder(dividingBy: 1)
                            let wrapped = phase < 0 ? phase + 1 : phase
                            guard wrapped < 0.5 else { continue }
                            // Slot is fixed — a time-rounded x was a visible jump every 3 s.
                            let x = (fi * 97.3).truncatingRemainder(dividingBy: max(1, Double(size.width)))
                            let grow = wrapped / 0.5
                            let alpha = (1 - grow) * 0.5
                            for side in [-1.0, 1.0] {
                                let dx = side * grow * 4
                                let dy = -sin(grow * .pi) * 3.5
                                context.fill(
                                    Path(ellipseIn: CGRect(
                                        x: x + dx, y: size.height - 2 + dy, width: 1.4, height: 1.4
                                    )),
                                    with: .color(.white.opacity(alpha))
                                )
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - light

    /// Crepuscular rays: a low sun behind broken cloud throws visible shafts.
    struct GodRays: View {
        var sunX: Double
        var sunY: Double
        var strength: Double
        var tint: Color

        var body: some View {
            Canvas { context, size in
                guard strength > 0.02 else { return }
                let origin = CGPoint(x: sunX * size.width, y: sunY * size.height)
                for i in 0..<5 {
                    let angle = -75.0 + Double(i) * 32 + 8
                    let rad = angle * .pi / 180
                    var path = Path()
                    let length = size.height * 0.9
                    let halfWidth = 11.0 + Double(i % 3) * 7
                    let dx = cos(rad), dy = -abs(sin(rad))
                    let tip = CGPoint(x: origin.x + dx * length, y: origin.y + dy * length)
                    let px = -dy, py = dx
                    path.move(to: origin)
                    path.addLine(to: CGPoint(x: tip.x + px * halfWidth, y: tip.y + py * halfWidth))
                    path.addLine(to: CGPoint(x: tip.x - px * halfWidth, y: tip.y - py * halfWidth))
                    path.closeSubpath()
                    var ray = context
                    ray.addFilter(.blur(radius: 10))
                    ray.opacity = 0.10 * strength
                    ray.fill(path, with: .color(tint))
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    /// A rainbow needs the sun at its back and rain in front — shown only in
    /// exactly that geometry, opposite the sun, feet on the horizon.
    struct Rainbow: View {
        var antiSolarX: Double
        var strength: Double

        private static let bands: [Color] = [
            Color(red: 0.90, green: 0.25, blue: 0.20),
            Color(red: 0.95, green: 0.62, blue: 0.20),
            Color(red: 0.95, green: 0.90, blue: 0.35),
            Color(red: 0.35, green: 0.80, blue: 0.40),
            Color(red: 0.30, green: 0.55, blue: 0.95),
            Color(red: 0.50, green: 0.35, blue: 0.85),
        ]

        var body: some View {
            Canvas { context, size in
                guard strength > 0.02 else { return }
                let center = CGPoint(x: antiSolarX * size.width, y: size.height * 1.32)
                for (index, colour) in Self.bands.enumerated() {
                    let radius = size.height * 0.78 - Double(index) * 4.0
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(180),
                        endAngle: .degrees(360),
                        clockwise: false
                    )
                    var arc = context
                    arc.addFilter(.blur(radius: 1.2))
                    arc.opacity = 0.34 * strength
                    arc.stroke(path, with: .color(colour), lineWidth: 3.4)
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    /// Aurora: green-to-violet curtains, waving slowly. Gated on the real
    /// planetary Kp index — from the Netherlands this is a Kp≥6.5 event.
    struct Aurora: View {
        var strength: Double
        var now: Date

        var body: some View {
            Canvas { context, size in
                guard strength > 0.02 else { return }
                let t = now.timeIntervalSinceReferenceDate
                for i in 0..<4 {
                    let fi = Double(i)
                    let baseX = size.width * (0.15 + fi * 0.22)
                    let sway = sin(t * 0.25 + fi * 1.7) * 22
                    let topY = size.height * 0.02
                    let bottomY = size.height * (0.30 + 0.05 * sin(t * 0.18 + fi))
                    var path = Path()
                    path.move(to: CGPoint(x: baseX + sway, y: topY))
                    path.addCurve(
                        to: CGPoint(x: baseX + sway * 0.4, y: bottomY),
                        control1: CGPoint(x: baseX + sway + 16, y: topY + 40),
                        control2: CGPoint(x: baseX + sway * 0.4 - 14, y: bottomY - 40)
                    )
                    let green = Color(red: 0.25, green: 0.95, blue: 0.55)
                    let violet = Color(red: 0.55, green: 0.30, blue: 0.90)
                    var curtain = context
                    curtain.addFilter(.blur(radius: 16))
                    curtain.opacity = 0.22 * strength
                    curtain.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [violet, green]),
                            startPoint: CGPoint(x: baseX, y: topY),
                            endPoint: CGPoint(x: baseX, y: bottomY)
                        ),
                        lineWidth: 26 + fi * 8
                    )
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    // MARK: - air

    /// Mist: soft horizontal bands low in the field when visibility drops.
    struct Mist: View {
        var strength: Double
        var tint: Color

        var body: some View {
            Canvas { context, size in
                guard strength > 0.02 else { return }
                for i in 0..<3 {
                    let fi = Double(i)
                    let y = size.height * (0.72 + fi * 0.09)
                    let rect = CGRect(x: -30, y: y, width: size.width + 60, height: 16 + fi * 8)
                    var band = context
                    band.addFilter(.blur(radius: 12))
                    band.opacity = (0.10 - fi * 0.02) * strength
                    band.fill(Path(ellipseIn: rect), with: .color(tint))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Wind-borne matter: pollen specks on dry summer wind, tumbling leaves
    /// in an autumn blow. Season decides which; wind decides how hard.
    struct WindDrift: View {
        var windKmh: Double
        var windDirection: Double
        var month: Int
        var dry: Bool
        var now: Date

        private var mode: Int {
            guard windKmh > 14, dry else { return 0 }
            if (9...11).contains(month) { return 2 }      // leaves
            if (5...8).contains(month) { return 1 }       // pollen/dust
            return 0
        }

        var body: some View {
            if mode > 0 {
                Canvas { context, size in
                    let t = now.timeIntervalSinceReferenceDate
                    let east = -sin(windDirection * .pi / 180)
                    let sign = east >= 0 ? max(0.22, east) : min(-0.22, east)
                    let count = mode == 2 ? 11 : 14
                    let travel = Double(size.width) + 40
                    for i in 0..<count {
                        let fi = Double(i)
                        let speed = (18 + windKmh * 1.4) * (0.7 + fi.truncatingRemainder(dividingBy: 4) * 0.15)
                        var x = (t * speed * sign + fi * 149).truncatingRemainder(dividingBy: travel)
                        if x < 0 { x += travel }
                        let px = x - 20
                        let y = size.height * (0.45 + 0.5 * ((fi * 0.37).truncatingRemainder(dividingBy: 1)))
                            + sin(t * 1.3 + fi) * 9
                        if mode == 2 {
                            let leaf = Color(
                                red: 0.75, green: 0.45 + fi.truncatingRemainder(dividingBy: 3) * 0.08, blue: 0.18
                            )
                            var ctx = context
                            ctx.translateBy(x: px, y: y)
                            ctx.rotate(by: .radians(t * 2 + fi))
                            ctx.opacity = 0.45
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: -3.4, y: -2.1, width: 6.8, height: 4.2)),
                                with: .color(leaf)
                            )
                        } else {
                            context.fill(
                                Path(ellipseIn: CGRect(x: px, y: y, width: 1.1, height: 1.1)),
                                with: .color(.white.opacity(0.22))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}


extension SkyLayers {
    /// Anamorphic flare: a long streak through the sun, a faint cross, and a
    /// run of warm/cool aperture ghosts toward the window's centre. Only when
    /// the sun itself is in frame and the air is mostly clear.
    struct LensFlare: View {
        var sunX: Double
        var sunY: Double
        var strength: Double
        var tint: Color

        var body: some View {
            Canvas { context, size in
                guard strength > 0.03 else { return }
                let sun = CGPoint(x: sunX * size.width, y: sunY * size.height)
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let cool = Color(red: 0.55, green: 0.78, blue: 1.0)

                // primary anamorphic streak
                var streak = context
                streak.addFilter(.blur(radius: 2.4))
                streak.opacity = 0.42 * strength
                streak.fill(
                    Path(CGRect(x: sun.x - 130, y: sun.y - 1.1, width: 260, height: 2.2)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, tint, .white, tint, .clear]),
                        startPoint: CGPoint(x: sun.x - 130, y: sun.y),
                        endPoint: CGPoint(x: sun.x + 130, y: sun.y)
                    )
                )

                // softer halo of the same streak
                var bloom = context
                bloom.addFilter(.blur(radius: 6))
                bloom.opacity = 0.18 * strength
                bloom.fill(
                    Path(CGRect(x: sun.x - 90, y: sun.y - 3.5, width: 180, height: 7)),
                    with: .color(tint)
                )

                // faint vertical spike — the plus of an anamorphic element
                var spike = context
                spike.addFilter(.blur(radius: 1.6))
                spike.opacity = 0.16 * strength
                spike.fill(
                    Path(CGRect(x: sun.x - 0.7, y: sun.y - 28, width: 1.4, height: 56)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .white, .clear]),
                        startPoint: CGPoint(x: sun.x, y: sun.y - 28),
                        endPoint: CGPoint(x: sun.x, y: sun.y + 28)
                    )
                )

                let ghosts: [(Double, Double, Double, Bool)] = [
                    (0.22, 4, 0.14, true),
                    (0.38, 7, 0.18, false),
                    (0.52, 3.5, 0.12, true),
                    (0.68, 11, 0.10, false),
                    (0.88, 5, 0.13, true),
                    (1.12, 15, 0.07, false),
                    (1.38, 6, 0.09, true),
                ]
                for (u, radius, alpha, warm) in ghosts {
                    let x = sun.x + (centre.x - sun.x) * 2 * u
                    let y = sun.y + (centre.y - sun.y) * 2 * u
                    var ghost = context
                    ghost.addFilter(.blur(radius: radius > 8 ? 3.2 : 1.6))
                    ghost.opacity = alpha * strength
                    ghost.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(warm ? tint : cool)
                    )
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }
}


extension SkyLayers {
    /// Film grain over the whole window — the analog skin. Warm-tinted while
    /// the sun is low, neutral at night. Fixed seed so it never crawls.
    struct Grain: View {
        var warmth: Double        // 0 neutral … 1 golden-hour warm
        var amount: Double        // 0…1

        var body: some View {
            Canvas { context, size in
                guard amount > 0.01 else { return }
                var seed: UInt64 = 0x6AA1
                func next() -> Double {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
                }
                let tint = Color(
                    red: 1.0,
                    green: 1.0 - 0.12 * warmth,
                    blue: 1.0 - 0.28 * warmth
                )
                for _ in 0..<480 {
                    let x = next() * size.width
                    let y = next() * size.height
                    let a = next() * 0.065 * amount
                    context.fill(
                        Path(CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(tint.opacity(a))
                    )
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    /// Thunderstorm: the field flashes, and every third strike shows its bolt.
    struct Lightning: View {
        var now: Date

        var body: some View {
            Canvas { context, size in
                let t = now.timeIntervalSinceReferenceDate
                let bucket = (t / 11).rounded(.down)
                var seed = UInt64(bitPattern: Int64(bucket))
                func next() -> Double {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
                }
                let offset = next() * 8
                let phase = t - bucket * 11 - offset
                guard phase > 0, phase < 0.45 else { return }
                let envelope = phase < 0.08
                    ? phase / 0.08
                    : max(0, 1 - (phase - 0.08) / 0.37)
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.white.opacity(0.10 * envelope))
                )
                guard Int(bucket) % 3 == 0 else { return }
                var x = 40 + next() * (size.width - 80)
                var y: Double = 0
                var bolt = Path()
                bolt.move(to: CGPoint(x: x, y: y))
                while y < size.height * 0.5 {
                    x += (next() - 0.48) * 34
                    y += 14 + next() * 22
                    bolt.addLine(to: CGPoint(x: x, y: y))
                }
                var strike = context
                strike.addFilter(.blur(radius: 0.6))
                strike.opacity = 0.75 * envelope
                strike.stroke(bolt, with: .color(.white), lineWidth: 1.3)
            }
            .allowsHitTesting(false)
        }
    }

    /// Condensation: droplets settle on the glass in fog or steady rain, and
    /// now and then one lets go and runs.
    struct Dew: View {
        var strength: Double

        var body: some View {
            if strength > 0.05 {
                TimelineView(.animation(minimumInterval: 1.0 / 6)) { timeline in
                    Canvas { context, size in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        var seed: UInt64 = 0xD1CE
                        func next() -> Double {
                            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                            return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
                        }
                        let count = Int(26 * strength)
                        for i in 0..<count {
                            let x = next() * size.width
                            var y = next() * size.height
                            let r = 0.7 + next() * 1.3
                            var alpha = 0.20
                            if i % 6 == 0 {
                                // Run a short way, fade, and stay gone — no wrap teleport.
                                let cycle = (t * 0.18 + next()).truncatingRemainder(dividingBy: 1)
                                let run = cycle < 0 ? cycle + 1 : cycle
                                if run > 0.62 {
                                    let u = (run - 0.62) / 0.38
                                    y += u * 36
                                    alpha *= max(0, 1 - u)
                                }
                            }
                            guard y < size.height, alpha > 0.02 else { continue }
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r * 1.25)),
                                with: .color(.white.opacity(alpha))
                            )
                            context.fill(
                                Path(ellipseIn: CGRect(x: x + r * 0.2, y: y + r * 0.15, width: r * 0.35, height: r * 0.35)),
                                with: .color(.white.opacity(min(0.35, alpha + 0.15)))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Snow gathering on a card's top edge — an uneven white cap that thickens
    /// with the snowfall.
    struct SnowCap: View {
        var style: WeatherSnapshot.PrecipStyle

        private var depth: Double? {
            switch style {
            case .flurry: 1.4
            case .snow: 2.4
            case .heavySnow: 3.6
            default: nil
            }
        }

        var body: some View {
            if let depth {
                Canvas { context, size in
                    var seed: UInt64 = 0x5104
                    func next() -> Double {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
                    }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    var x: Double = 0
                    while x < size.width {
                        let bump = depth * (0.5 + next())
                        path.addLine(to: CGPoint(x: x, y: size.height - bump))
                        x += 5 + next() * 9
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(.white.opacity(0.55)))
                }
                .allowsHitTesting(false)
            }
        }
    }
}
