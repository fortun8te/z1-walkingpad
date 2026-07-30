// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Z1WalkingPad",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Z1Core", targets: ["Z1Core"]),
        .executable(name: "Z1MenuBar", targets: ["Z1MenuBar"]),
        .executable(name: "z1smoke", targets: ["Z1Smoke"]),
    ],
    targets: [
        .target(name: "Z1Core"),
        .target(name: "Z1CoreTestSuite", dependencies: ["Z1Core"]),
        .executableTarget(name: "Z1MenuBar", dependencies: ["Z1Core"]),
        .executableTarget(name: "Z1Smoke", dependencies: ["Z1Core"]),
        .executableTarget(name: "z1tests", dependencies: ["Z1CoreTestSuite"]),
        .testTarget(name: "Z1CoreTests", dependencies: ["Z1Core", "Z1CoreTestSuite"]),
    ]
)
