// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TetherWasm",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TetherWasm", targets: ["TetherWasm"]),
    ],
    targets: [
        .target(
            name: "CWasm3",
            path: "Sources/CWasm3",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-Wno-sign-compare"])]
        ),
        .target(
            name: "TetherWasm",
            dependencies: ["CWasm3"],
            path: "Sources/TetherWasm",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-Wno-unused-parameter"]),
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),
    ]
)
