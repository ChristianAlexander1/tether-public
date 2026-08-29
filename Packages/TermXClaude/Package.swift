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
            resources: [
                // bun-compat is a CommonJS package: `.process` would flatten
                // lib/ into the bundle root and break its internal requires.
                .copy("Resources/bun-compat"),
                .process("Resources/launcher.js"),
                .process("Resources/bun-shim.js"),
                .process("Resources/registry.json"),
                .process("Resources/NOTICE-claude-bun-bridge.txt"),
            ]
        ),
        .testTarget(
            name: "TermXClaudeTests",
            dependencies: ["TermXClaude"],
            path: "Tests/TermXClaude"
        ),
    ]
)
