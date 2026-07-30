import Foundation
import SwiftUI
import Z1Core

/// ObservableObject bridge between the `Z1Treadmill` actor and SwiftUI.
///
/// All BLE-facing values stay metric (km/h, meters, kg — the wire protocol
/// requires it); conversion to the user's display units happens here.
@MainActor
final class TreadmillViewModel: ObservableObject {
    @Published private(set) var status = Z1Treadmill.Status()
    @Published private(set) var busy = false
    @Published private(set) var lastSummary: SessionSummary?

    // MARK: - persisted settings (UserDefaults — the same store @AppStorage uses)

    /// Body weight, always stored in kg (canonical); displayed/edited in the
    /// current unit via `weightBinding`. Fed to the calorie math in kg.
    @Published var weightKg: Double {
        didSet {
            UserDefaults.standard.set(weightKg, forKey: Self.weightKey)
            Task { await treadmill.setWeight(weightKg) }
        }
    }

    /// Display units: true = Imperial (mph/mi/lb), false = Metric. Changing it
    /// also syncs the pad's own LED display (best-effort).
    @Published var unitsImperial: Bool {
        didSet {
            UserDefaults.standard.set(unitsImperial, forKey: Self.unitsKey)
            Task { try? await treadmill.setDisplayUnits(imperial: unitsImperial) }
        }
    }

    /// +/- stepper nudge size, in the CURRENT display unit (mph or km/h).
    @Published var speedStep: Double {
        didSet {
            UserDefaults.standard.set(speedStep, forKey: Self.stepKey)
        }
    }

    let treadmill = Z1Treadmill()
    private var pumpTask: Task<Void, Never>?

    static let weightKey = "weightKg"
    static let unitsKey = "unitsImperial"
    static let stepKey = "speedStep"

    init() {
        let defaults = UserDefaults.standard
        let storedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = storedWeight > 0 ? storedWeight : Z1Metrics.defaultWeightKg
        // default Imperial for new users; respect a previously saved choice
        unitsImperial = defaults.object(forKey: Self.unitsKey) as? Bool ?? true
        let storedStep = defaults.double(forKey: Self.stepKey)
        speedStep = storedStep > 0 ? storedStep : 0.1

        Task { await treadmill.setWeight(weightKg) }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await s in self.treadmill.statusUpdates {
                guard !Task.isCancelled else { break }
                self.status = s
            }
        }
    }

    var isConnected: Bool { status.phase == .ready }

    // MARK: - display-unit helpers

    var speedUnitLabel: String { unitsImperial ? "mph" : "km/h" }
    var weightUnitLabel: String { unitsImperial ? "lb" : "kg" }

    /// Current belt speed in the display unit (for the readout + menu bar).
    var displaySpeed: Double {
        unitsImperial ? Z1Units.kmhToMph(status.speedKmh) : status.speedKmh
    }

    /// Weight field binding: shows/edits in the current unit, stores kg.
    var weightBinding: Binding<Double> {
        Binding(
            get: { self.unitsImperial ? Z1Units.kgToLb(self.weightKg) : self.weightKg },
            set: { self.weightKg = self.unitsImperial ? Z1Units.lbToKg($0) : $0 }
        )
    }

    /// Speed-step nudge expressed in km/h for the wire protocol.
    private var speedStepKmh: Double {
        unitsImperial ? Z1Units.mphToKmh(speedStep) : speedStep
    }

    func formatDistance(_ meters: Int) -> String {
        if unitsImperial {
            let miles = Z1Units.metersToMiles(Double(meters))
            return miles < 0.1
                ? "\(Int(Z1Units.metersToFeet(Double(meters)).rounded())) ft"
                : String(format: "%.2f mi", miles)
        }
        return meters >= 1000
            ? String(format: "%.2f km", Double(meters) / 1000)
            : "\(meters) m"
    }

    // MARK: - actions

    func connectTapped() {
        guard !busy else { return }
        run {
            if self.isConnected {
                await self.treadmill.disconnect()
            } else {
                try await self.treadmill.connect()
                // If the pad's own display units disagree with the persisted
                // setting, push our setting down (best-effort).
                let props = await self.treadmill.status.properties
                let padImperial = Z1Units.propertyIndicatesImperial(props[1] ?? 0)
                if padImperial != self.unitsImperial {
                    try? await self.treadmill.setDisplayUnits(imperial: self.unitsImperial)
                }
            }
        }
    }

    func startStopTapped() {
        guard !busy, isConnected else { return }
        run {
            if self.status.beltRunning {
                let summary = try await self.treadmill.stop()
                self.lastSummary = summary
            } else {
                self.lastSummary = nil
                try await self.treadmill.start()
            }
        }
    }

    func speedUpTapped() {
        guard !busy, isConnected, status.beltRunning else { return }
        run { _ = try await self.treadmill.speedUp(deltaKmh: self.speedStepKmh) }
    }

    func speedDownTapped() {
        guard !busy, isConnected, status.beltRunning else { return }
        run { _ = try await self.treadmill.speedDown(deltaKmh: self.speedStepKmh) }
    }

    func quit() {
        let treadmill = self.treadmill
        Task {
            // Always disconnect cleanly before exiting (this also stops the
            // belt if it's running) — but never hang on exit: if BLE doesn't
            // answer within 3s, terminate anyway.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await treadmill.disconnect() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.terminate(nil)
        }
    }

    private func run(_ op: @MainActor @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await op()
            } catch {
                // surfaced via status.errorMessage for connect; log the rest
                NSLog("Z1MenuBar: \(error.localizedDescription)")
            }
        }
    }
}
