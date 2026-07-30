import Z1CoreTestSuite
import Z1Core

// This machine builds with Command Line Tools only — no XCTest or
// swift-testing module ships with CLT, so `swift test` has no runner that can
// execute tests. The unit tests therefore live in the framework-free
// `Z1CoreTestSuite` library (compiled and typechecked here, so `swift test`
// still builds them) and are executed by `swift run z1tests`, which exits
// non-zero on failure.
//
// Referencing the entry point forces the suite to link into the test bundle.
enum SuiteAnchor {
    static let runAll: @Sendable () -> Int32 = runAllZ1CoreTests
}
