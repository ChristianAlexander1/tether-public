// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TetherJobControl",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TetherJobControl", targets: ["TetherJobControl"]),
    ],
    targets: [
        .target(
            name: "TetherJobControl",
            dependencies: []
        ),
        .testTarget(
            name: "TetherJobControlTests",
            dependencies: ["TetherJobControl"]
        ),
    ]
)
