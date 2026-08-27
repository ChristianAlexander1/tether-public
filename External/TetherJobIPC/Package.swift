// swift-tools-version:5.9
//
// TetherJobIPC — server side of TJIP/2.
//
// The core product (`TetherJobIPC`) is a pure, Foundation-only library with
// zero third-party dependencies and no threading primitives. `TetherJobIPCTestSupport`
// ships the in-memory fake `JIPHostDelegate` and the golden-frame fixtures used by
// the test target. See HANDOFF.md for the serial-queue and flow-control model.

import PackageDescription

let package = Package(
    name: "TetherJobIPC",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TetherJobIPC", targets: ["TetherJobIPC"]),
        .library(name: "TetherJobIPCTestSupport", targets: ["TetherJobIPCTestSupport"]),
    ],
    targets: [
        .target(
            name: "TetherJobIPC"
        ),
        .target(
            name: "TetherJobIPCTestSupport",
            dependencies: ["TetherJobIPC"],
            path: "Tests/TetherJobIPCTestSupport"
        ),
        .testTarget(
            name: "TetherJobIPCTests",
            dependencies: ["TetherJobIPC", "TetherJobIPCTestSupport"]
        ),
    ]
)
