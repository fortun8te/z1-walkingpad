import Foundation
import SwiftUI
import Z1Core

/// ObservableObject bridge between the `Z1Treadmill` actor and SwiftUI.
@MainActor
final class TreadmillViewModel: ObservableObject {
    @Published private(set) var status = Z1Treadmill.Status()
    @Published private(set) var busy = false
    @Published private(set) var lastSummary: SessionSummary?

    /// Body weight used for the calorie estimate. Persisted via @AppStorage key.
    @Published var weightKg: Double {
        didSet {
            UserDefaults.standard.set(weightKg, forKey: Self.weightKey)
            Task { await treadmill.setWeight(weightKg) }
        }
    }

    let treadmill = Z1Treadmill()
    private var pumpTask: Task<Void, Never>?

    static let weightKey = "weightKg"

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.weightKey)
        weightKg = stored > 0 ? stored : Z1Metrics.defaultWeightKg
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

    func connectTapped() {
        guard !busy else { return }
        run {
            if self.isConnected {
                await self.treadmill.disconnect()
            } else {
                try await self.treadmill.connect()
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
        run { _ = try await self.treadmill.speedUp() }
    }

    func speedDownTapped() {
        guard !busy, isConnected, status.beltRunning else { return }
        run { _ = try await self.treadmill.speedDown() }
    }

    func quit() {
        Task {
            await treadmill.disconnect()
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
