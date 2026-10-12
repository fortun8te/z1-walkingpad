import CoreGraphics
import Foundation
import ImageIO
import Z1Core

// A small, shaped patch of sky light over a dark field. Weather changes its
// colour and strength without painting literal clouds across the panel.
// The images are cached and painted off the main thread.

typealias RGB = SIMD3<Double>

@inline(__always) private func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * min(1, max(0, t)) }
@inline(__always) private func sat01(_ x: Double) -> Double { min(1, max(0, x)) }
@inline(__always) private func sstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = sat01((x - a) / (b - a)); return t * t * (3 - 2 * t)
}
@inline(__always) private func wrap180(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    return x
}
@inline(__always) private func luma(_ c: RGB) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func cg(_ c: RGB, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(sat01(c.x)), CGFloat(sat01(c.y)), CGFloat(sat01(c.z)), CGFloat(sat01(a))])!
}

private func hex(_ v: UInt32) -> RGB {
    RGB(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

// MARK: - palette

/// Four vertical stops (top → horizon) and the colour of the horizon bloom.
struct SkyPalette: Sendable {
    var stops: [RGB]
    var bloom: RGB
    var bloomStrength: Double

    private struct Key {
        var e: Double
        var stops: [RGB]
        var bloom: RGB
        var strength: Double
    }

    // Evening side: violet → coral dusk, charcoal-plum evening, navy night.
    private static let evening: [Key] = [
        Key(e: -18, stops: [hex(0x05060F), hex(0x090B1C), hex(0x121632), hex(0x2A2250)], bloom: hex(0x8A4C8C), strength: 0.30),
        Key(e: -10, stops: [hex(0x0C0B14), hex(0x1C1628), hex(0x33243F), hex(0x5C3A48)], bloom: hex(0xB86A6E), strength: 0.42),
        Key(e: -4, stops: [hex(0x271F2F), hex(0x4F3A78), hex(0x865AB4), hex(0xE4804E)], bloom: hex(0xF08A50), strength: 0.55),
        Key(e: 1, stops: [hex(0x232A55), hex(0x5A4E8C), hex(0xC47C8A), hex(0xFFA25A)], bloom: hex(0xFFA050), strength: 0.62),
        Key(e: 6, stops: [hex(0x1B3A70), hex(0x4D6FA8), hex(0xD9B08E), hex(0xFFCB7A)], bloom: hex(0xFFD08A), strength: 0.52),
        Key(e: 18, stops: [hex(0x1A4FA8), hex(0x3F82D2), hex(0x96C0EC), hex(0xEDE6D6)], bloom: hex(0xFFF4DE), strength: 0.34),
        Key(e: 45, stops: [hex(0x1450B8), hex(0x3A86DA), hex(0x8EC2EE), hex(0xDCE6F2)], bloom: hex(0xFFFFFF), strength: 0.30),
    ]

    // Morning side: navy → dusty lavender twilight, teal-blue → peach dawn.
    private static let morning: [Key] = [
        Key(e: -18, stops: [hex(0x05060F), hex(0x090B1C), hex(0x121632), hex(0x2A2250)], bloom: hex(0x8A4C8C), strength: 0.30),
        Key(e: -10, stops: [hex(0x0A1020), hex(0x1A2744), hex(0x4A5478), hex(0x9C8290)], bloom: hex(0xC49098), strength: 0.40),
        Key(e: -4, stops: [hex(0x14324A), hex(0x0E5E94), hex(0x3F8FC8), hex(0xFDC492)], bloom: hex(0xFFB880), strength: 0.55),
        Key(e: 1, stops: [hex(0x163F66), hex(0x2A74B4), hex(0x9DB4CC), hex(0xFFC282)], bloom: hex(0xFFB060), strength: 0.60),
        Key(e: 6, stops: [hex(0x184C8E), hex(0x4486CA), hex(0xB8C8DC), hex(0xFFD99A)], bloom: hex(0xFFDDA0), strength: 0.48),
        Key(e: 18, stops: [hex(0x1A4FA8), hex(0x3F82D2), hex(0x96C0EC), hex(0xEDE6D6)], bloom: hex(0xFFF4DE), strength: 0.34),
        Key(e: 45, stops: [hex(0x1450B8), hex(0x3A86DA), hex(0x8EC2EE), hex(0xDCE6F2)], bloom: hex(0xFFFFFF), strength: 0.30),
    ]

    private static func sample(_ keys: [Key], _ e: Double) -> Key {
        if e <= keys[0].e { return keys[0] }
        if e >= keys[keys.count - 1].e { return keys[keys.count - 1] }
        for i in 0..<(keys.count - 1) where e <= keys[i + 1].e {
            let a = keys[i], b = keys[i + 1]
            let t = sstep(0, 1, (e - a.e) / (b.e - a.e))
            return Key(
                e: e,
                stops: (0..<4).map { mix(a.stops[$0], b.stops[$0], t) },
                bloom: mix(a.bloom, b.bloom, t),
                strength: a.strength + (b.strength - a.strength) * t
            )
        }
        return keys[keys.count - 1]
    }

    /// Every date gets its own evening: some go rose, some gold. Seeded from
    /// the calendar day, so the sky never changes its mind between glances.
    static func dayCharacter(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var seed = UInt64((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((seed >> 33) & 0xFFFF) / 65_535 * 2 - 1
    }

    init(scene s: SkyScene) {
        let e = s.sunElevation
        // Morning vs evening, continuous through noon and midnight.
        let m = sstep(-0.6, 0.6, sin(s.sunAzimuth * .pi / 180))
        let ev = Self.sample(Self.evening, e), mo = Self.sample(Self.morning, e)
        var st = (0..<4).map { mix(ev.stops[$0], mo.stops[$0], m) }
        var bl = mix(ev.bloom, mo.bloom, m)
        var strength = ev.strength + (mo.strength - ev.strength) * m

        // The day's character, only around sunset/sunrise.
        let lowSun = max(0, 1 - abs(e) / 8)
        if lowSun > 0 {
            let drift = Self.dayCharacter(s.date) * lowSun
            let rose = RGB(0.96, 0.52, 0.62), gold = RGB(1.0, 0.76, 0.42)
            st[3] = mix(st[3], drift < 0 ? rose : gold, abs(drift) * 0.25)
            bl = mix(bl, drift < 0 ? rose : gold, abs(drift) * 0.2)
        }

        let daylight = 1 - s.darkness

        // Cloud: greys and flattens the ramp, softens the bloom. A closed lid
        // keeps its time-of-day hue only faintly.
        let c = pow(s.cloudTotal, 1.2) * (1 - 0.4 * s.breakthrough) * (1 - 0.3 * s.rainbow)
        if c > 0 {
            let mean = st.reduce(RGB(0, 0, 0), +) / 4
            for i in 0..<4 {
                let grey = RGB(repeating: luma(st[i])) * RGB(0.97, 1.0, 1.06)
                st[i] = mix(st[i], grey, 0.62 * c)
                st[i] = mix(st[i], mix(mean, grey, 0.5), 0.30 * c)
            }
            // Overcast days go a little dimmer; overcast nights catch town light.
            if daylight > 0.3 {
                for i in 0..<4 { st[i] *= 1 - 0.14 * c * daylight }
            } else {
                st[3] = mix(st[3], hex(0x3A2E34), 0.45 * c)
                st[2] = mix(st[2], hex(0x1E1A24), 0.35 * c)
            }
            strength *= 1 - 0.55 * c
            bl = mix(bl, RGB(repeating: luma(bl)), 0.5 * c)
        }

        // Rain cools and darkens; snow cools and lifts.
        if s.precip != .none {
            let i = 0.45 + 0.55 * s.precipIntensity
            if s.precip.isSnowlike {
                for k in 0..<4 { st[k] = mix(st[k], mix(st[k], RGB(0.80, 0.85, 0.92) * (0.3 + 0.7 * daylight), 0.5), 0.45 * i) }
            } else {
                let cool = RGB(0.30, 0.37, 0.48) * (0.25 + 0.75 * daylight)
                for k in 0..<4 {
                    st[k] = mix(st[k], cool * (0.6 + 0.4 * Double(k) / 3), 0.40 * i)
                    st[k] *= 1 - 0.25 * i
                }
                strength *= 1 - 0.35 * i
            }
        }

        // Storm: slate, and the top goes heavy.
        if s.lightning > 0.3 {
            let slate = RGB(0.16, 0.19, 0.24) * (0.35 + 0.65 * daylight)
            for k in 0..<4 { st[k] = mix(st[k], slate * (0.7 + 0.2 * Double(k)), 0.45) }
        }

        // Fog: milk, thickest at the ground.
        if s.fog > 0 {
            let milk = mix(RGB(0.11, 0.11, 0.13), RGB(0.78, 0.79, 0.80), pow(daylight, 0.7))
            for k in 0..<4 { st[k] = mix(st[k], milk * (0.75 + 0.08 * Double(k)), s.fog * (0.35 + 0.18 * Double(k))) }
            bl = mix(bl, milk, 0.6 * s.fog)
        }

        // A falling barometer (and heavy weather in general) weighs on the top.
        st[0] *= 1 - 0.40 * s.heaviness
        st[1] *= 1 - 0.22 * s.heaviness

        // Moonlight lifts a clear night's lower sky a touch.
        if s.darkness > 0.4, s.moonElevation > 0 {
            let moon = s.moonIllumination * (1 - 0.8 * s.cloudTotal) * s.darkness
            st[2] = mix(st[2], hex(0x2A3A6A), 0.25 * moon)
            st[1] = mix(st[1], hex(0x16204A), 0.2 * moon)
        }

        stops = st
        bloom = bl
        bloomStrength = strength
    }
}

// MARK: - projection

/// A camera standing in Amersfoort, horizon on the bottom edge, one scale
/// for both axes so the rainbow's 42° is a true circle.
struct SkyProjection: Sendable {
    var size: CGSize
    var viewAzimuth: Double
    var ptPerDeg: Double
    var horizonY: Double

    init(size: CGSize, viewAzimuth: Double) {
        self.size = size
        self.viewAzimuth = viewAzimuth
        ptPerDeg = Double(size.width) / 74
        horizonY = Double(size.height) + 4
    }

    /// Top-left origin.
    func point(azimuth: Double, elevation: Double) -> CGPoint {
        CGPoint(
            x: Double(size.width) / 2 + wrap180(azimuth - viewAzimuth) * ptPerDeg,
            y: horizonY - elevation * ptPerDeg
        )
    }

    /// Face the rainbow when there is one (sun at your back, as it must be),
    /// the moon on a moonlit night, otherwise the sun — leaning so the
    /// morning light sits left and the evening light right.
    static func viewAzimuth(for s: SkyScene) -> Double {
        if s.rainbow > 0.05 { return s.rainbowGeometry.centerAzimuth }
        func lean(_ az: Double) -> Double { az - max(-28, min(28, wrap180(az - 180) * 0.3)) }
        if s.darkness > 0.6, s.moonElevation > -2, s.moonIllumination > 0.08 { return lean(s.moonAzimuth) }
        return lean(s.sunAzimuth)
    }
}

// MARK: - output

/// Two cached bitmaps: the painted field, and the soft light pools that
/// drift very slowly on top of it.
struct SkyFrame: @unchecked Sendable {
    var size: CGSize
    var back: CGImage
    /// Oversized by `blobInset` on every side so drifting never shows an edge.
    var blobs: CGImage?
    var blobInset: CGFloat
    var horizonGlow: CGColor
}

enum SkyRenderer {
    static let blobInset: CGFloat = 24

    static func render(scene s: SkyScene, size: CGSize, scale: CGFloat, previous: SkyFrame?) -> SkyFrame? {
        _ = previous
        let view = SkyProjection.viewAzimuth(for: s)
        let proj = SkyProjection(size: size, viewAzimuth: view)
        let pal = SkyPalette(scene: s)
        guard let back = drawBack(s, pal, proj, scale: scale) else { return nil }
        // The pools are soft: half resolution is indistinguishable and a quarter of the work.
        let blobs = drawBlobs(s, pal, proj, scale: max(1, scale / 2))
        return SkyFrame(
            size: size, back: back, blobs: blobs, blobInset: blobInset,
            horizonGlow: cg(mix(pal.stops[3], pal.bloom, 0.5))
        )
    }

    // MARK: helpers

    private static func context(_ size: CGSize, scale: CGFloat) -> CGContext? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        return ctx
    }

    private static func radial(_ ctx: CGContext, at c: CGPoint, stops: [(Double, RGB, Double)], radius: Double) {
        let colors = stops.map { cg($0.1, $0.2) } as CFArray
        let locs = stops.map { CGFloat($0.0) }
        guard let g = CGGradient(colorsSpace: sRGB, colors: colors, locations: locs) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(radius), options: [])
    }

    /// A soft pool: many stops along a smooth falloff, so there is no visible rim.
    private static func pool(_ ctx: CGContext, at c: CGPoint, colour: RGB, alpha: Double, radius: Double, squash: Double = 1) {
        guard alpha > 0.003 else { return }
        var stops: [(Double, RGB, Double)] = []
        for i in 0...12 {
            let t = Double(i) / 12
            let f = pow(1 - sstep(0, 1, t), 1.6)
            stops.append((t, colour, alpha * f))
        }
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: CGFloat(squash))
        radial(ctx, at: .zero, stops: stops, radius: radius)
        ctx.restoreGState()
    }

    struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
        }
    }

    /// Fine static grain, made once. It also breaks gradient banding.
    private static let grainTile: CGImage? = {
        let n = 128
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var r = Rand(state: 0x6A11_4E57)
        for i in 0..<(n * n) {
            let v = r.next()
            let white = v > 0.5
            let a = UInt8(abs(v - 0.5) * 2 * 3) // sub-1.2% dither, not visible film grain
            let c: UInt8 = white ? a : 0
            px[i * 4] = c; px[i * 4 + 1] = c; px[i * 4 + 2] = c; px[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }()

    // MARK: the field

    private static func drawBack(_ s: SkyScene, _ p: SkyPalette, _ proj: SkyProjection, scale: CGFloat) -> CGImage? {
        guard let ctx = context(proj.size, scale: scale) else { return nil }
        let W = Double(proj.size.width), H = Double(proj.size.height)

        let daylight = 1 - s.darkness
        ctx.setFillColor(cg(mix(hex(0x080910), hex(0x0A1020), daylight)))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // The brightest area sits behind the speed control. A cool shoulder
        // and a smaller warm spill make the colour feel local, not like a
        // full-height wallpaper. Each pool has a soft edge.
        let sunPt = proj.point(azimuth: s.sunAzimuth, elevation: s.sunElevation)
        let sunSide = sat01(sunPt.x / W)
        let primaryX = W * (0.48 + 0.13 * (sunSide - 0.5))
        let weatherDim = 1 - 0.40 * s.heaviness - 0.22 * s.fog
        let nightDim = 0.62 + 0.38 * daylight
        pool(ctx, at: CGPoint(x: primaryX, y: H * 0.13),
             colour: p.stops[1], alpha: 0.94 * weatherDim * nightDim,
             radius: W * 1.22, squash: 0.76)
        pool(ctx, at: CGPoint(x: W * 0.84, y: H * 0.08),
             colour: p.stops[2], alpha: 0.51 * weatherDim * nightDim,
             radius: W * 0.72, squash: 0.82)
        pool(ctx, at: CGPoint(x: W * 0.18, y: H * 0.35),
             colour: p.bloom, alpha: p.bloomStrength * 0.31 * weatherDim,
             radius: W * 0.66, squash: 0.62)
        let twilight = sstep(-12, -3, s.sunElevation) * (1 - sstep(3, 16, s.sunElevation))
        if twilight > 0.01 {
            let morning = sin(s.sunAzimuth * .pi / 180) > 0
            pool(ctx, at: CGPoint(x: W * (morning ? 0.14 : 0.86), y: H * 0.35),
                 colour: p.bloom, alpha: 0.56 * twilight * weatherDim,
                 radius: W * 0.60, squash: 0.72)
        }

        // Darken the lower half even when the weather palette is pale. The
        // almanac and navigation then rest over stable dark material.
        let shadeStops: [(Double, RGB, Double)] = [
            (0, hex(0x080910), 0), (0.37, hex(0x080910), 0.03),
            (0.68, hex(0x080910), 0.70), (1, hex(0x080910), 0.98),
        ]
        if let shade = CGGradient(colorsSpace: sRGB, colors: shadeStops.map { cg($0.1, $0.2) } as CFArray,
                                  locations: shadeStops.map { CGFloat($0.0) }) {
            ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        }

        // 2. Stars: a few tiny faint points, only on a genuinely clear dark night.
        if s.stars > 0.25 {
            var r = Rand(state: 0x9E37_79B9_7F4A_7C15)
            for _ in 0..<48 {
                let x = r.next() * W, y = r.next() * H * 0.62
                let mag = pow(r.next(), 2.5)
                let a = s.stars * (0.12 + 0.38 * mag)
                let d = 0.6 + 0.6 * mag
                ctx.setFillColor(cg(RGB(0.92, 0.94, 1.0), a))
                ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
            }
        }

        // 3. Moon: a soft glow disc at its real position, brightness by phase.
        let moonPt = proj.point(azimuth: s.moonAzimuth, elevation: s.moonElevation)
        if s.moonElevation > 0, s.darkness > 0.25, moonPt.x > -40, moonPt.x < W + 40 {
            let clear = sat01(1 - 0.8 * min(1, s.cloudLow + 0.8 * s.cloudMid) - 0.7 * s.fog)
            let k = s.moonIllumination
            let a = clear * s.darkness * (0.25 + 0.75 * k)
            if a > 0.02 {
                let tone = s.moonElevation < 10 ? RGB(1.0, 0.90, 0.78) : RGB(0.93, 0.95, 1.0)
                pool(ctx, at: moonPt, colour: tone, alpha: 0.16 * a, radius: 70)
                radial(ctx, at: moonPt, stops: [(0, tone, 0.85 * a), (0.45, tone, 0.75 * a), (0.75, tone, 0.2 * a), (1, tone, 0)], radius: 8)
            }
        }

        // 4. Sun: light, not an object — a soft bloom, tighter when the beam is strong.
        if s.sunElevation > -1.5 {
            let f = s.sunFraction
            let warm = mix(p.bloom, RGB(1, 1, 1), sstep(10, 40, s.sunElevation) * 0.6)
            ctx.saveGState(); ctx.setBlendMode(.screen)
            pool(ctx, at: CGPoint(x: sunPt.x, y: min(sunPt.y, H * 0.48)), colour: warm,
                 alpha: (0.09 + 0.16 * f) * (1 - 0.5 * s.fog), radius: 90)
            ctx.restoreGState()
        }

        // 5. Breakthrough: the measured beam through a cloudy sky is a warm
        //    bloom that floods the lower sky.
        if s.breakthrough > 0.02 {
            ctx.saveGState(); ctx.setBlendMode(.screen)
            let warm = mix(p.bloom, RGB(1.0, 0.92, 0.74), 0.5)
            pool(ctx, at: CGPoint(x: primaryX, y: H * 0.27), colour: warm,
                 alpha: 0.22 * s.breakthrough, radius: W * 0.75, squash: 0.65)
            ctx.restoreGState()
        }

        // 6. Rainbow weather adds a trace of spectral colour in the lit area.
        if s.rainbow > 0.02 {
            ctx.saveGState(); ctx.setBlendMode(.screen)
            pool(ctx, at: CGPoint(x: W * 0.18, y: H * 0.30), colour: RGB(0.70, 0.45, 0.86),
                 alpha: 0.10 * s.rainbow, radius: W * 0.42, squash: 0.6)
            pool(ctx, at: CGPoint(x: W * 0.71, y: H * 0.36), colour: RGB(0.85, 0.78, 0.48),
                 alpha: 0.09 * s.rainbow, radius: W * 0.43, squash: 0.6)
            ctx.restoreGState()
        }

        // 7. Rain is a trace in the light, never a layer over the controls.
        if s.precip != .none, !s.precip.isSnowlike {
            var r = Rand(state: 0x0072_A1F0)
            let slant = 0.18
            let a = 0.010 + 0.012 * s.precipIntensity
            ctx.setLineCap(.round)
            for _ in 0..<16 {
                let x = r.next() * (W + 120) - 60, y = r.next() * H * 0.42
                let len = 60 + r.next() * 80
                ctx.setStrokeColor(cg(RGB(0.85, 0.9, 1.0), a * (0.5 + 0.5 * r.next())))
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x - len * slant, y: y + len))
                ctx.strokePath()
            }
        }

        // 8. Fine, static grain breaks banding.
        if let tile = grainTile {
            ctx.saveGState()
            ctx.scaleBy(x: 1 / scale, y: 1 / scale) // one grain pixel per device pixel
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: 128, height: 128), byTiling: true)
            ctx.restoreGState()
        }

        return ctx.makeImage()
    }

    // MARK: the drifting light pools

    private static func drawBlobs(_ s: SkyScene, _ p: SkyPalette, _ proj: SkyProjection, scale: CGFloat) -> CGImage? {
        let inset = Double(blobInset)
        let W = Double(proj.size.width), H = Double(proj.size.height)
        let size = CGSize(width: W + 2 * inset, height: H + 2 * inset)
        guard let ctx = context(size, scale: scale) else { return nil }
        ctx.translateBy(x: CGFloat(inset), y: CGFloat(inset))

        let sunPt = proj.point(azimuth: s.sunAzimuth, elevation: s.sunElevation)
        let sunX = min(W * 0.85, max(W * 0.15, sunPt.x))
        let st = p.stops

        // The drift is only a change in light, not a second full sky.
        ctx.saveGState(); ctx.setBlendMode(.screen)
        pool(ctx, at: CGPoint(x: sunX, y: H * 0.22), colour: p.bloom,
             alpha: p.bloomStrength * 0.24, radius: W * 0.70, squash: 0.7)
        let counter = mix(st[2], st[1], 0.3) * 1.15
        pool(ctx, at: CGPoint(x: W - sunX * 0.8, y: H * 0.12), colour: counter,
             alpha: 0.13, radius: W * 0.68, squash: 0.75)
        if s.darkness > 0.5 {
            pool(ctx, at: CGPoint(x: sunX * 0.6 + W * 0.2, y: H * 0.32),
                 colour: RGB(0.18, 0.28, 0.85), alpha: 0.10 * s.darkness * (1 - 0.6 * s.cloudTotal),
                 radius: W * 0.55, squash: 0.6)
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

// MARK: - debug composite (Z1_SKY_DUMP=/path.png)

extension SkyRenderer {
    static func dump(_ f: SkyFrame, to path: String) {
        let size = f.size
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: 2, y: 2)
        ctx.interpolationQuality = .high
        ctx.draw(f.back, in: CGRect(origin: .zero, size: size))
        if let b = f.blobs {
            ctx.draw(b, in: CGRect(x: -f.blobInset, y: -f.blobInset, width: size.width + 2 * f.blobInset, height: size.height + 2 * f.blobInset))
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
