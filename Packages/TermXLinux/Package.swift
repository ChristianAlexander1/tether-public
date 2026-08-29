// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let frameworksRoot = packageDir.appendingPathComponent("../../Frameworks").standardizedFileURL
let blinkSrc = frameworksRoot.appendingPathComponent(".build/blink-src").path
// `build-blink.sh` installs the host archive to Frameworks/.build/host/.
let blinkLib = frameworksRoot.appendingPathComponent(".build/host/blink.a").path
let blinkXCFrameworkURL = frameworksRoot.appendingPathComponent("Blink.xcframework")
let blinkInclude = frameworksRoot.appendingPathComponent("include").path
let hostConfig = frameworksRoot.appendingPathComponent(".build/host/config.h").path
let linkBlink = (Context.environment["TETHER_LINK_BLINK"]
    ?? Context.environment["TERMX_LINK_BLINK"]) == "1"
let hasBlinkXCFramework = FileManager.default.fileExists(atPath: blinkXCFrameworkURL.path)

let iosBlinkFlags = [
    "-fno-modules",
    "-I", blinkInclude,
    "-include", "\(blinkInclude)/config.h",
    "-iquote", blinkSrc,
    "-D_DARWIN_C_SOURCE",
    "-DNDEBUG",
]
let hostBlinkFlags = [
    "-fno-modules",
    "-I", blinkInclude,
    "-include", hostConfig,
    "-iquote", blinkSrc,
    "-D_DARWIN_C_SOURCE",
    "-DNDEBUG",
]

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

// iOS production links Blink.xcframework (ios-arm64 / simulator). That binary
// has no macOS slice, so macOS must not inherit TERMX_BLINK_STUB from this
// branch — otherwise TETHER_LINK_BLINK=1 can never compile the real bridge.
if hasBlinkXCFramework {
    packageTargets.append(
        .binaryTarget(
            name: "BlinkBinary",
            path: "../../Frameworks/Blink.xcframework"
        )
    )
    bridgeDeps.append("BlinkBinary")
    bridgeSettings += [
        .unsafeFlags(iosBlinkFlags, .when(platforms: [.iOS])),
    ]
} else {
    bridgeSettings += [
        .define("TERMX_BLINK_STUB", .when(platforms: [.iOS])),
    ]
}

if linkBlink {
    bridgeSettings += [
        .unsafeFlags(hostBlinkFlags, .when(platforms: [.macOS])),
    ]
    bridgeLinker += [
        .unsafeFlags([blinkLib], .when(platforms: [.macOS])),
    ]
} else {
    bridgeSettings += [
        .define("TERMX_BLINK_STUB", .when(platforms: [.macOS])),
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
        dependencies: [
            "TermXCore",
            "TermXBlinkBridge",
            .product(name: "TetherStorageCore", package: "TetherStorageCore"),
        ],
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
        .package(path: "../../External/TetherStorageCore"),
    ],
    targets: packageTargets
)
