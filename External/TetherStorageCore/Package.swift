// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TetherStorageCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "TetherStorageCore",
            targets: ["TetherStorageCore"]
        )
    ],
    targets: [
        .target(name: "TetherStorageCore"),
        .testTarget(
            name: "TetherStorageCoreTests",
            dependencies: ["TetherStorageCore"]
        )
    ]
)
