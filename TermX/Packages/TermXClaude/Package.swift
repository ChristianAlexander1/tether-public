// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermXClaude",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXClaude", targets: ["TermXClaude"]),
    ],
    targets: [
        .target(
            name: "TermXClaude",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TermXClaudeTests",
            dependencies: ["TermXClaude"]
        ),
    ]
)
