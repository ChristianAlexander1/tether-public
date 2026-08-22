// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let frameworksRoot = packageDir.appendingPathComponent("../../Frameworks").standardizedFileURL
let blinkSrc = frameworksRoot.appendingPathComponent(".build/blink-src").path
let blinkLib = frameworksRoot.appendingPathComponent(".build/blink/host/blink.a").path
let blinkXCFrameworkURL = frameworksRoot.appendingPathComponent("Blink.xcframework")
let blinkInclude = frameworksRoot.appendingPathComponent("include").path
let linkBlink = Context.environment["TERMX_LINK_BLINK"] == "1"
let hasBlinkXCFramework = FileManager.default.fileExists(atPath: blinkXCFrameworkURL.path)

var bridgeSettings: [CSetting] = [
    .headerSearchPath("include"),
]
var bridgeLinker: [LinkerSetting] = [
    .linkedLibrary("z"),
    .linkedLibrary("m"),
    .linkedLibrary("pthread"),
]
var bridgeDeps: [Target.Dependency] = []
var packageTargets: [Target] = []

if hasBlinkXCFramework {
    packageTargets.append(
        .binaryTarget(
            name: "BlinkBinary",
            path: "../../Frameworks/Blink.xcframework"
        )
    )
    bridgeDeps.append("BlinkBinary")
    // Real bridge on iOS (linked against Blink.xcframework). macOS package tests keep
    // the stub unless TERMX_LINK_BLINK=1 (host blink.a + HostBlinkRuntime path).
    bridgeSettings += [
        .define("TERMX_BLINK_STUB", .when(platforms: [.macOS])),
        .unsafeFlags([
            "-fno-modules",
            "-I", blinkInclude,
            "-include", "\(blinkInclude)/config.h",
            "-iquote", blinkSrc,
            "-D_DARWIN_C_SOURCE",
            "-DNDEBUG",
        ], .when(platforms: [.iOS])),
    ]
} else if linkBlink {
    bridgeSettings += [
        .unsafeFlags([
            "-I", blinkSrc,
            "-include", "\(blinkSrc)/config.h",
            "-iquote", blinkSrc,
            "-D_DARWIN_C_SOURCE",
            "-DNDEBUG",
        ], .when(platforms: [.macOS])),
    ]
    bridgeLinker += [
        .unsafeFlags([blinkLib], .when(platforms: [.macOS])),
    ]
} else {
    bridgeSettings += [
        .define("TERMX_BLINK_STUB"),
    ]
}

packageTargets += [
    .target(
        name: "TermXBlinkBridge",
        dependencies: bridgeDeps,
        path: "Sources/TermXBlinkBridge",
        publicHeadersPath: "include",
        cSettings: bridgeSettings,
        linkerSettings: bridgeLinker
    ),
    .target(
        name: "TermXLinux",
        dependencies: ["TermXCore", "TermXBlinkBridge"],
        resources: [
            .process("Resources"),
        ]
    ),
    .testTarget(
        name: "TermXLinuxTests",
        dependencies: ["TermXLinux"]
    ),
]

let package = Package(
    name: "TermXLinux",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXLinux", targets: ["TermXLinux"]),
    ],
    dependencies: [
        .package(path: "../TermXCore"),
    ],
    targets: packageTargets
)
