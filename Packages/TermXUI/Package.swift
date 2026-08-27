// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermXUI",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXUI", targets: ["TermXUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(path: "../TermXFiles"),
        .package(path: "../../External/TetherTerminal"),
        .package(path: "../../External/TetherVTEngine"),
    ],
    targets: [
        .target(
            name: "TermXUI",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "TermXFiles", package: "TermXFiles"),
                .product(name: "TetherVTEngine", package: "TetherVTEngine"),
            ],
            path: "Sources/TermXUI",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TermXUITests",
            dependencies: [
                "TermXUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "TetherTerminal", package: "TetherTerminal"),
            ],
            path: "Tests/TermXUITests"
        )
    ]
)
