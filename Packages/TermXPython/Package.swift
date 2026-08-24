// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Host (macOS) test runs dlopen Python extension modules whose install names are
// @rpath-relative to the directory containing Python.framework; point rpath there.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let macSliceDir = "\(packageDir)/Vendor/TermXPython.xcframework/macos-arm64_x86_64"

let package = Package(
    name: "TermXPython",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXPython", targets: ["TermXPython"]),
    ],
    targets: [
        .binaryTarget(
            name: "TermXPythonBinary",
            path: "Vendor/TermXPython.xcframework"
        ),
        .target(
            name: "TermXPythonBridge",
            dependencies: ["TermXPythonBinary"],
            path: "Sources/TermXPythonBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("PythonHeaders"),
            ],
        ),
        .target(
            name: "TermXPython",
            dependencies: ["TermXPythonBridge"],
            path: "Sources/TermXPython",
            resources: [
                .process("Resources/registry.json"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", macSliceDir,
                              "-Xlinker", "-rpath", "-Xlinker", "\(macSliceDir)/Python.framework/Versions/3.14/lib"],
                             .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "TermXPythonTests",
            dependencies: ["TermXPython"],
            path: "Tests/TermXPython",
            exclude: ["Fixtures/termx-demo"],
            resources: [
                .copy("Fixtures/wheel-index"),
            ]
        ),
    ]
)
