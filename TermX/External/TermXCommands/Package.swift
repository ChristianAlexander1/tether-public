// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermXCommands",
    platforms: [.macOS(.v11), .iOS(.v16)],
    products: [
        .library(name: "TermXCommands", targets: ["TermXCommands"])
    ],
    targets: [
        .target(name: "TermXCommands"),
        .testTarget(name: "TermXCommandsTests", dependencies: ["TermXCommands"]),
    ],
    swiftLanguageVersions: [.v5]
)
