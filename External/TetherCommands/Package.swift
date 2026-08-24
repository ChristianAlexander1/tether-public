// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TetherCommands",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(name: "TetherCommands", targets: ["TetherCommands"])
    ],
    targets: [
        .target(name: "TetherCommands"),
        .testTarget(name: "TetherCommandsTests", dependencies: ["TetherCommands"])
    ]
)
