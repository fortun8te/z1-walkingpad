import AppKit
import Combine
import CoreLocation
import Foundation
import Z1Core

/// What the sky is doing right now, in words and a few numbers.
struct SkyConditions: Equatable {
    var sunElevation: Double
    var isDaylight: Bool
    /// e.g. "Light rain · 1008 hPa falling · sunset 19:32"
    var summary: String
    /// e.g. "Golden hour in 12 min"
    var nextEvent: String?
    /// Extras for anyone who wants them.
    var phrase: String = ""
    var pressure: Double?
    var pressureTendency: String?
    var moonPhase: String = ""
    var updatedAt: Date?
}

/// The one source of sky truth.
///
/// Work only happens while someone is looking: `setVisible(true)` starts a
/// once-a-minute scene tick and a ten-minute weather refresh; `false` stops
/// both and leaves a single 30-minute background refresh (one small HTTP
/// request, no rendering). Rendering is off the main thread and cached; the
/// view animates the cached layers in Core Animation.
@MainActor
final class SkyEngine: ObservableObject {
    static let shared = SkyEngine()

    @Published private(set) var conditions: SkyConditions
    @Published private(set) var scene: SkyScene
    /// Latest painted frame for the backdrop.
    @Published private(set) var frame: SkyFrame?

    private(set) var weather: WeatherSnapshot?
    private var kp: Double = 0
    private var visible = false
    private var minuteTimer: Timer?
    private var backgroundTimer: Timer?
    private var fetching = false
    private var lastAttempt: Date = .distantPast
    private var renderSize = CGSize(width: 312, height: 548)
    private var renderScale: CGFloat = 2
    private var rendering = false
    private var pendingRender = false
    private var lastRenderKey: String?

    static let visibleRefresh: TimeInterval = 10 * 60
    static let backgroundRefresh: TimeInterval = 30 * 60
    /// After a failed request, wait at least this long — no retry storms.
    static let failureBackoff: TimeInterval = 5 * 60

    private init() {
        let clock = SkyEngine.clock()
        let date = SkyEngine.skyDate(now: Date())
        let w = SkyEngine.effectiveWeather(cached: OpenMeteo.cached(), at: date, clock: clock)
        weather = w
        kp = SkyEngine.simKp ?? SpaceWeather.cachedKp() ?? 0
        let s = SkyModel.evaluate(date: date, weather: w, clock: clock, kp: kp)
        scene = s
        conditions = SkyEngine.describe(s, weather: w, clock: clock)
        scheduleBackground()
    }

    // MARK: visibility

    func setVisible(_ newValue: Bool) {
        guard newValue != visible else { return }
        visible = newValue
        if visible {
            backgroundTimer?.invalidate(); backgroundTimer = nil
            tick(forceRender: frame == nil)
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick(forceRender: false) }
            }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            minuteTimer = t
        } else {
            minuteTimer?.invalidate(); minuteTimer = nil
            scheduleBackground()
        }
    }

    var isVisible: Bool { visible }

    /// The backdrop tells the engine how big to paint.
    func setRenderSize(_ size: CGSize, scale: CGFloat) {
        guard size.width > 10, size.height > 10 else { return }
        let s = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard s != renderSize || scale != renderScale else { return }
        renderSize = s
        renderScale = scale
        requestRender(force: true)
    }

    private func scheduleBackground() {
        backgroundTimer?.invalidate()
        guard !Self.isSimulating else { return }
        let t = Timer(timeInterval: Self.backgroundRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWeather(maxAge: SkyEngine.backgroundRefresh - 60) }
        }
        t.tolerance = 5 * 60
        RunLoop.main.add(t, forMode: .common)
        backgroundTimer = t
    }

    // MARK: the minute tick

    private func tick(forceRender: Bool) {
        recompute()
        refreshWeather(maxAge: Self.visibleRefresh)
        requestRender(force: forceRender)
    }

    private func recompute() {
        let clock = Self.clock()
        let date = Self.skyDate(now: Date())
        if Self.isSimulating { weather = Self.effectiveWeather(cached: weather, at: date, clock: clock) }
        let s = SkyModel.evaluate(date: date, weather: Self.fresh(weather, at: Date()), clock: clock, kp: Self.simKp ?? kp)
        scene = s
        let c = Self.describe(s, weather: Self.fresh(weather, at: Date()), clock: clock)
        if c != conditions { conditions = c }
    }

    /// A snapshot older than three hours is history, not weather.
    private static func fresh(_ w: WeatherSnapshot?, at now: Date) -> WeatherSnapshot? {
        guard let w else { return nil }
        if isSimulating { return w }
        return now.timeIntervalSince(w.fetchedAt) < 3 * 3_600 ? w : nil
    }

    private func refreshWeather(maxAge: TimeInterval) {
        guard !Self.isSimulating, !fetching else { return }
        let now = Date()
        if let w = weather, now.timeIntervalSince(w.fetchedAt) < maxAge { return }
        guard now.timeIntervalSince(lastAttempt) > Self.failureBackoff || weather == nil && now.timeIntervalSince(lastAttempt) > 60 else { return }
        lastAttempt = now
        fetching = true
        let loc = Self.location()
        let wantKp = scene.darkness > 0.3 || scene.sunElevation < 3
        Task { [weak self] in
            let fresh = await OpenMeteo.refresh(latitude: loc.latitude, longitude: loc.longitude)
            let newKp = wantKp ? await SpaceWeather.kp() : nil
            await MainActor.run {
                guard let self else { return }
                self.fetching = false
                if let fresh { self.weather = fresh }
                if let newKp { self.kp = newKp }
                if fresh != nil || newKp != nil {
                    self.recompute()
                    if self.visible { self.requestRender(force: false) }
                }
            }
        }
    }

    // MARK: rendering

    private func renderKey(_ s: SkyScene) -> String {
        let q = { (x: Double, n: Double) in Int((x * n).rounded()) }
        return [
            q(s.sunElevation, 2), q(s.sunAzimuth, 0.5), q(s.moonElevation, 1), q(s.moonAzimuth, 0.5),
            q(s.cloudLow, 20), q(s.cloudMid, 20), q(s.cloudHigh, 20), q(s.sunFraction, 10),
            q(s.rainbow, 20), q(s.breakthrough, 20), q(s.fog, 20), q(s.haze, 10), q(s.stars, 20),
            q(s.heaviness, 20), q(s.precipIntensity, 10), q(s.lightning, 5), q(s.aurora, 10), q(s.halo, 10),
            q(s.windSpeed, 0.25), q(s.windDirection, 0.1),
        ].map(String.init).joined(separator: ",") + s.precip.rawValue
            + "\(Int(renderSize.width))x\(Int(renderSize.height))@\(renderScale)"
    }

    private func requestRender(force: Bool) {
        guard visible || frame == nil else { return }
        let key = renderKey(scene)
        guard force || key != lastRenderKey else { return }
        if rendering { pendingRender = true; return }
        rendering = true
        lastRenderKey = key
        let s = scene, size = renderSize, scale = renderScale, previous = frame
        Task.detached(priority: .utility) {
            let started = Date()
            let f = SkyRenderer.render(scene: s, size: size, scale: scale, previous: previous)
            let ms = Date().timeIntervalSince(started) * 1_000
            await MainActor.run {
                let engine = SkyEngine.shared
                let env = ProcessInfo.processInfo.environment
                if env["Z1_SKY_LOG"] == "1" {
                    FileHandle.standardError.write(Data(String(
                        format: "Z1_SKY render %.0f ms  el %.1f az %.0f  rainbow %.2f break %.2f sunF %.2f fog %.2f stars %.2f moon %.0f/%.0f %.2f heavy %.2f precip %@ | %@ | %@\n",
                        ms, s.sunElevation, s.sunAzimuth, s.rainbow, s.breakthrough, s.sunFraction, s.fog, s.stars, s.moonElevation, s.moonAzimuth, s.moonIllumination, s.heaviness,
                        s.precip.rawValue, engine.conditions.summary, engine.conditions.nextEvent ?? "-"
                    ).utf8))
                }
                if let path = env["Z1_SKY_DUMP"], let f { SkyRenderer.dump(f, to: path) }
                if let f { engine.frame = f }
                engine.rendering = false
                if engine.pendingRender {
                    engine.pendingRender = false
                    engine.requestRender(force: false)
                }
            }
        }
    }

    // MARK: words

    static func describe(_ s: SkyScene, weather w: WeatherSnapshot?, clock: SolarClock) -> SkyConditions {
        SkyConditions(
            sunElevation: s.sunElevation,
            isDaylight: s.sunElevation > -0.833,
            summary: SkyNarrative.summary(scene: s, weather: w, clock: clock),
            nextEvent: SkyNarrative.nextEvent(scene: s, weather: w, clock: clock),
            phrase: SkyNarrative.phrase(scene: s, weather: w),
            pressure: w?.pressure,
            pressureTendency: s.tendency?.word,
            moonPhase: MoonPhase.name(at: s.date),
            updatedAt: w?.fetchedAt
        )
    }

    // MARK: location — CoreLocation only if already authorised; never prompts

    static let defaultLocation = CLLocationCoordinate2D(latitude: 52.156, longitude: 5.388)

    static func location() -> CLLocationCoordinate2D {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            if let c = manager.location?.coordinate, CLLocationCoordinate2DIsValid(c) {
                UserDefaults.standard.set([c.latitude, c.longitude], forKey: "z1.skyLocation")
                return c
            }
        default:
            break
        }
        if let saved = UserDefaults.standard.array(forKey: "z1.skyLocation") as? [Double], saved.count == 2 {
            return CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
        }
        return defaultLocation
    }

    static func clock() -> SolarClock {
        if let saved = UserDefaults.standard.array(forKey: "z1.skyLocation") as? [Double], saved.count == 2 {
            return SolarClock(latitude: saved[0], longitude: saved[1])
        }
        return SolarClock()
    }

    // MARK: simulator (hidden)
    //
    //   defaults write dev.z1walkingpad.menubar z1.skySimHour -float 17.5
    //   defaults write dev.z1walkingpad.menubar z1.skySimDate 2026-06-21
    //   defaults write dev.z1walkingpad.menubar z1.skySimWeather rainbow
    //     clear | partly | overcast | rain | drizzle | downpour | snow | heavysnow
    //     fog | storm | sunshower | windy | rainbow | breakthrough | halo
    //   defaults write dev.z1walkingpad.menubar z1.skySimKp -float 7.5
    // The sim still obeys the physics: `rainbow` at a sun below 0° or above
    // 42° shows showers and no bow. Delete the keys to return to reality.

    static var isSimulating: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "z1.skySimHour") != nil || d.string(forKey: "z1.skySimDate") != nil
            || d.string(forKey: "z1.skySimWeather") != nil
    }

    static var simKp: Double? {
        let d = UserDefaults.standard
        return d.object(forKey: "z1.skySimKp") != nil ? d.double(forKey: "z1.skySimKp") : nil
    }

    static func skyDate(now: Date) -> Date {
        let d = UserDefaults.standard
        let simDay = d.string(forKey: "z1.skySimDate")
        let hasHour = d.object(forKey: "z1.skySimHour") != nil
        guard simDay != nil || hasHour else { return now }
        var base = now
        if let simDay {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            if let parsed = f.date(from: simDay) { base = parsed }
        }
        let start = Calendar.current.startOfDay(for: base)
        if hasHour { return start.addingTimeInterval(d.double(forKey: "z1.skySimHour") * 3_600) }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return start.addingTimeInterval(Double((c.hour ?? 12) * 3_600 + (c.minute ?? 0) * 60 + (c.second ?? 0)))
    }

    static func effectiveWeather(cached: WeatherSnapshot?, at date: Date, clock: SolarClock) -> WeatherSnapshot? {
        guard let name = UserDefaults.standard.string(forKey: "z1.skySimWeather") else {
            return isSimulating ? cached.map { var w = $0; w.fetchedAt = date; return w } : cached
        }
        let e = clock.position(at: date).elevation
        let dni = { (share: Double) -> Double in SunBeam.clearSkyDNI(elevation: e) * 0.85 * share }
        func w(_ cover: Double, _ precip: Double, _ code: Int, low: Double? = nil, mid: Double = 0, high: Double = 0,
               showers: Double = 0, nearby: Double? = nil, wind: Double = 12, dir: Double = 240, press: Double = 1_013,
               change: Double? = 0.2, vis: Double = 25_000, hum: Double = 0.7, beam: Double? = nil,
               cape: Double = 0, lpi: Double = 0) -> WeatherSnapshot {
            WeatherSnapshot(
                cloudCover: cover, precipitation: precip, weatherCode: code, cloudLow: low, cloudMid: mid, cloudHigh: high,
                showers: showers, precipitationNearby: nearby, windSpeed: wind, windDirection: dir, pressure: press,
                pressureChange3h: change, visibility: vis, humidity: hum, directNormal: beam.map(dni),
                cape: cape, lightningPotential: lpi, fetchedAt: date
            )
        }
        switch name {
        case "clear": return w(0.03, 0, 0, low: 0, high: 0.03, press: 1_024, change: 0.6, beam: 1)
        case "partly": return w(0.45, 0, 2, low: 0.35, mid: 0.2, high: 0.25, press: 1_017, beam: 0.8)
        case "overcast": return w(1, 0, 3, low: 0.95, mid: 0.6, press: 1_009, change: -0.4, beam: 0)
        case "rain": return w(1, 1.4, 63, low: 1, mid: 0.8, wind: 22, press: 1_003, change: -2.1, vis: 8_000, hum: 0.94, beam: 0)
        case "drizzle": return w(1, 0.2, 53, low: 1, wind: 10, press: 1_008, change: -1.2, vis: 5_000, hum: 0.97, beam: 0)
        case "downpour": return w(1, 7, 65, low: 1, mid: 1, wind: 30, press: 997, change: -3.2, vis: 3_000, hum: 0.98, beam: 0)
        case "snow": return w(1, 0.8, 73, low: 0.95, mid: 0.5, wind: 14, dir: 60, press: 1_010, vis: 3_000, hum: 0.92, beam: 0)
        case "heavysnow": return w(1, 2.5, 75, low: 1, mid: 0.8, wind: 26, dir: 60, press: 1_002, change: -2, vis: 900, hum: 0.96, beam: 0)
        case "fog": return w(0.35, 0, 45, low: 0.3, wind: 3, press: 1_026, change: 0.1, vis: 250, hum: 0.99, beam: 0.1)
        case "storm": return w(0.95, 4.5, 95, low: 0.9, mid: 0.85, high: 0.6, wind: 38, dir: 210, press: 998, change: -4.4,
                               vis: 6_000, hum: 0.9, beam: 0, cape: 1_900, lpi: 6)
        case "sunshower": return w(0.5, 0.5, 80, low: 0.45, mid: 0.2, showers: 0.5, wind: 16, press: 1_009, change: 1.1, beam: 0.8)
        case "windy": return w(0.45, 0, 2, low: 0.45, mid: 0.1, wind: 48, dir: 250, press: 1_001, change: -1.8, beam: 0.7)
        case "rainbow": return w(0.6, 0.4, 80, low: 0.5, mid: 0.3, showers: 0.4, nearby: 1.6, wind: 18, dir: 260,
                                 press: 1_007, change: 1.6, vis: 30_000, hum: 0.82, beam: 0.85, cape: 450)
        case "breakthrough": return w(0.8, 0, 3, low: 0.7, mid: 0.4, high: 0.2, wind: 14, press: 1_012, change: 0.8, beam: 0.8)
        case "halo": return w(0.6, 0, 2, low: 0.02, mid: 0.05, high: 0.6, wind: 9, press: 1_016, change: -0.9, beam: 0.75)
        default: return cached
        }
    }
}
