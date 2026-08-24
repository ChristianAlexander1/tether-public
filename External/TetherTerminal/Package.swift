// swift-tools-version:5.9
//
// TetherTerminal — VT100/xterm escape sequence parser
//

import PackageDescription

let package = Package(
    name: "TetherTerminal",
    products: [
        .library(
            name: "TetherTerminal",
            targets: ["TetherTerminal"]
        ),
    ],
    targets: [
        .target(
            name: "TetherTerminal",
            path: "Sources/TetherTerminal"
        ),
        .testTarget(
            name: "TetherTerminalTests",
            dependencies: ["TetherTerminal"],
            path: "Tests/TetherTerminalTests"
        ),
    ]
)
