// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "TermXCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TermXCore", targets: ["TermXCore"])],
    dependencies: [
        .package(path: "../../External/TermXCommands"),
        .package(path: "../../External/TetherCommands"),
        .package(path: "../../External/TermXShellLang"),
    ],
    targets: [
        .target(
            name: "TermXCore",
            dependencies: ["TermXCommands", "TetherCommands", "TermXShellLang"],
            resources: [.process("Resources/registry.json")],
            publicHeadersPath: "include"
        ),
        .testTarget(name: "TermXCoreTests", dependencies: ["TermXCore", "TermXShellLang"])
    ]
)
