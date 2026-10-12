import AppKit
import Foundation
import Z1Core

/// The UI harness. `Z1_PREVIEW=1 Z1App -z1.hasSeenIntro 1` opens the window
/// with no Bluetooth and a scratch history, prints `Z1_PREVIEW_WINDOW <n>`,
/// and `screencapture -l <n>` takes the picture.
///
/// Environment:
/// - `Z1_PREVIEW_PHASE` ready | scanning | disconnected
/// - `Z1_PREVIEW_SPEED` belt speed in km/h; above 0 means walking
/// - `Z1_PREVIEW_QUEUED` a speed (km/h) queued for Start at a standstill
/// - `Z1_PREVIEW_PAGE` now | history | records | settings
/// - `Z1_PREVIEW_LENS` day | week | month
/// - `Z1_PREVIEW_DEMO=1` five weeks of plausible walks (otherwise empty)
/// - `Z1_PREVIEW_ERROR` speed | stop injects a visible simulated command failure
/// - `Z1_PREVIEW_TICK=1` fake telemetry once a second, for CPU measurement
/// - `Z1_PREVIEW_APPEARANCE` light | dark (otherwise the system's)
///
/// It never touches the real history: the store is a scratch file.
@MainActor
enum PreviewHarness {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var tickTimer: Timer?

    static var page: Page? {
        guard TreadmillViewModel.isPreview else { return nil }
        return Page(rawValue: env["Z1_PREVIEW_PAGE"] ?? "")
    }

    static var lens: TreadmillViewModel.AlmanacLens? {
        guard TreadmillViewModel.isPreview else { return nil }
        return TreadmillViewModel.AlmanacLens(rawValue: env["Z1_PREVIEW_LENS"] ?? "")
    }

    static var appearance: NSAppearance? {
        guard TreadmillViewModel.isPreview else { return nil }
        switch env["Z1_PREVIEW_APPEARANCE"] {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    static func sessionStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(env["Z1_PREVIEW_DEMO"] == "1" ? demoSessions() : []).write(to: url)
        return SessionStore(url: url)
    }

    private static func demoSessions() -> [WalkSession] {
        var sessions: [WalkSession] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let minutes = [180, 120, 131, 96, 0, 58, 122, 0, 88, 140, 45, 0, 102, 67, 118, 0, 0, 93, 127, 81,
                       0, 110, 64, 99, 0, 135, 72, 0, 105, 90, 0, 41, 0, 116, 0]
        for (offset, min) in minutes.enumerated() where min > 0 {
            guard let day = calendar.date(byAdding: .day, value: -(offset + 1), to: today),
                  let start = calendar.date(byAdding: .hour, value: 10 + offset % 5, to: day)
            else { continue }
            let seconds = min * 60
            let metres = Int(Double(seconds) * 3.3 / 3.6)
            sessions.append(WalkSession(
                id: "demo-\(offset)", startedAt: start, endedAt: start.addingTimeInterval(Double(seconds + 120)),
                activeDurationS: seconds, distanceM: metres, steps: Int(Double(metres) / 0.62),
                caloriesKcal: Double(min) * 3.6, exportedToHealth: false
            ))
        }
        if let first = calendar.date(byAdding: .hour, value: 9, to: today) {
            sessions.append(WalkSession(
                id: "demo-today", startedAt: first, endedAt: first.addingTimeInterval(2_700),
                activeDurationS: 2_580, distanceM: 2_360, steps: 3_810, caloriesKcal: 152, exportedToHealth: false
            ))
        }
        return sessions.sorted { $0.startedAt < $1.startedAt }
    }

    /// Fake telemetry: one frame now and, with `Z1_PREVIEW_TICK=1`, one a
    /// second after that, through the same path real frames take.
    static func start(_ model: TreadmillViewModel) {
        var s = Z1Treadmill.Status()
        s.deviceName = "KS-ST-Z1"
        switch env["Z1_PREVIEW_PHASE"] ?? "ready" {
        case "scanning": s.phase = .scanning
        case "disconnected": s.phase = .disconnected
        default: s.phase = .ready
        }
        let speed = Double(env["Z1_PREVIEW_SPEED"] ?? "") ?? 0
        if s.phase == .ready {
            s.hasTelemetry = true
            s.speedKmh = speed
            s.beltRunning = speed > 0
            if speed > 0 {
                s.elapsedS = 1_934
                s.distanceM = 1_812
                s.steps = 3_120
                s.caloriesKcal = 96
                s.impliedStrideM = 0.58
            }
        }
        model.setStatus(s)
        switch env["Z1_PREVIEW_ERROR"] {
        case "speed": model.previewSetCommandError("Speed change failed. The last confirmed speed is shown.")
        case "stop": model.previewSetCommandError("Stop failed. The belt may still be moving. Try Stop again.")
        default: break
        }
        if let queued = Double(env["Z1_PREVIEW_QUEUED"] ?? "") { model.previewQueueSpeed(queued) }
        guard env["Z1_PREVIEW_TICK"] == "1", s.beltRunning else { return }
        var distance = Double(s.distanceM)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                var next = model.status
                next.elapsedS += 1
                distance += next.speedKmh / 3.6
                next.distanceM = Int(distance)
                next.steps = Int(distance / 0.58)
                next.caloriesKcal += 0.06
                model.setStatus(next)
                model.observeWalk()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }
}
