// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermX",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TermX", targets: ["TermXIntegration"])],
    dependencies: [
        .package(path: "Packages/TermXUI"),
        .package(path: "Packages/TermXCore"),
        .package(path: "Packages/TermXFiles"),
        .package(path: "Packages/TermXPython"),
        .package(path: "Packages/TermXNode"),
        .package(path: "Packages/TermXClaude"),
        .package(path: "Packages/TermXLinux"),
        .package(path: "External/TetherWasm"),
        .package(path: "External/TetherSessionCore"),
        .package(path: "External/TetherStorageCore")
    ],
    targets: [
        .target(name: "TermXIntegration", dependencies: [
            .product(name: "TermXUI", package: "TermXUI"),
            .product(name: "TermXCore", package: "TermXCore"),
            .product(name: "TermXFiles", package: "TermXFiles"),
            .product(name: "TermXPython", package: "TermXPython"),
            .product(name: "TermXNode", package: "TermXNode"),
            .product(name: "TermXClaude", package: "TermXClaude"),
            .product(name: "TermXLinux", package: "TermXLinux"),
            .product(name: "TetherWasm", package: "TetherWasm"),
            .product(name: "TetherSessionCore", package: "TetherSessionCore"),
            .product(name: "TetherStorageCore", package: "TetherStorageCore")
        ], path: "App/IntegrationSource"),
        .testTarget(name: "TermXIntegrationTests", dependencies: ["TermXIntegration"], path: "App/IntegrationTests")
    ]
)
