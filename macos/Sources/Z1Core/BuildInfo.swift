import Foundation

/// Which build is running: the version and build number the release script
/// writes into the app's Info.plist (`2.0`, and the minute it was built as
/// `yyyyMMddHHmm`). A run outside a bundle (`swift run`) has neither.
public struct BuildInfo: Equatable, Sendable {
    public let version: String?
    public let build: String?

    public init(info: [String: Any]?) {
        version = info?["CFBundleShortVersionString"] as? String
        build = info?["CFBundleVersion"] as? String
    }

    public init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary)
    }

    /// "Z1 2.0 (build 202610131200)", or "Z1 (development build)" without one.
    public var line: String {
        guard let version, let build else { return "Z1 (development build)" }
        return "Z1 \(version) (build \(build))"
    }
}
