import Foundation
import Testing
@testable import Z1App

/// Models a native callback that cannot be cancelled by its awaiting task.
private actor PendingNativeTeardown {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite(.serialized)
@MainActor
struct ShutdownDeadlineTests {
    @Test func deadlineReturnsBeforeUncooperativeNativeCallback() async {
        let native = PendingNativeTeardown()
        // Keeps a broken implementation from hanging the test process forever.
        let fallback = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            await native.release()
        }
        var timeouts = 0
        await BoundedShutdown.run(timeout: .milliseconds(20), operation: {
            await native.wait()
        }, onTimeout: {
            timeouts += 1
        })
        #expect(timeouts == 1)
        #expect(await !native.released, "Quit must return while the native callback is still pending")
        await native.release()
        fallback.cancel()
        // The late completion must not resume Quit a second time.
        await Task.yield()
        #expect(timeouts == 1)
    }

    @Test func completedTeardownCancelsItsTimeout() async {
        var timedOut = false
        await BoundedShutdown.run(timeout: .seconds(1), operation: {}, onTimeout: {
            timedOut = true
        })
        #expect(!timedOut)
    }
}
