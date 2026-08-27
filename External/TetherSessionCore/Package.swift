// swift-tools-version:5.9
//
// TetherSessionCore — pure-Swift core for the terminal session lifecycle.
// Foundation-only, zero dependencies, no threads/timers.
//
// swift build / swift test must pass on Linux Swift 5.9+.

import PackageDescription

let package = Package(
    name: "TetherSessionCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TetherSessionCore", targets: ["TetherSessionCore"]),
    ],
    targets: [
        .target(
            name: "TetherSessionCore",
            path: "Sources/TetherSessionCore"
        ),
        .testTarget(
            name: "TetherSessionCoreTests",
            dependencies: ["TetherSessionCore"],
            path: "Tests/TetherSessionCoreTests"
        ),
    ]
)
