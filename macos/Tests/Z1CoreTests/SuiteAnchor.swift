import Z1CoreTestSuite
import Z1Core

// Core assertions remain framework-free so Command Line Tools users can run
// them with `swift run z1tests`. `swift test` links this anchor but does not
// execute those assertions; the separate Z1AppTests suite uses Swift Testing
// with full Xcode and Z1_PREVIEW=1 to isolate storage and Bluetooth.
//
// Referencing the entry point forces the suite to link into the test bundle.
enum SuiteAnchor {
    static let runAll: @Sendable () async -> Int32 = runAllZ1CoreTests
}
