import Foundation

/// Minimal framework-free test harness.
///
/// Why this exists: this machine has Command Line Tools only (no Xcode), and
/// neither XCTest nor swift-testing ships with CLT — `swift test` can compile
/// the test target but has no runner to execute it. So the unit tests live in
/// this plain library, are compiled by the `Tests/` target (so `swift test`
/// typechecks and links them), and are actually executed by the `z1tests`
/// executable (`swift run z1tests`), which exits non-zero on any failure.
public final class TestRunner {
    public private(set) var checks = 0
    public private(set) var failures = 0
    private var currentSuite = ""

    public init() {}

    public func suite(_ name: String, _ body: (TestRunner) -> Void) {
        currentSuite = name
        body(self)
    }

    public func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL [\(currentSuite)] \(message)")
        }
    }

    public func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
        check(got == want, "\(message) — got \(got), want \(want)")
    }

    public func expectEqual(_ got: Double, _ want: Double, accuracy: Double, _ message: String) {
        check(abs(got - want) <= accuracy, "\(message) — got \(got), want \(want) ±\(accuracy)")
    }

    public func expectNil<T: Equatable>(_ value: T?, _ message: String) {
        check(value == nil, "\(message) — got \(String(describing: value)), want nil")
    }
}
