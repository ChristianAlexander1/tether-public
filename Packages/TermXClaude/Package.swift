// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermXClaude",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXClaude", targets: ["TermXClaude"]),
    ],
    dependencies: [
        .package(path: "../TermXCore"),
    ],
    targets: [
        .target(
            name: "TermXClaude",
            dependencies: ["TermXCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TermXClaudeTests",
            dependencies: ["TermXClaude"]
        ),
    ]
)
