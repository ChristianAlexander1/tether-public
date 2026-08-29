// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "TermXCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TermXCore", targets: ["TermXCore"])],
    dependencies: [
        // TermXCommands: specialized host-shell tools (sed/awk/stat/…).
        // TetherCommands: POSIX utilities TermXCommands does not provide.
        // They are complementary registries, not two copies of one library.
        .package(path: "../../External/TermXCommands"),
        .package(path: "../../External/TetherCommands"),
        // Production host-shell evaluator.
        .package(path: "../../External/TermXShellLang"),
        // Conformance oracle used only by TermXCoreTests — not linked into
        // the app. Do not add it to the TermXCore target.
        .package(path: "../../External/TetherShellLang"),
    ],
    targets: [
        .target(
            name: "TermXCore",
            dependencies: ["TermXCommands", "TetherCommands", "TermXShellLang"],
            resources: [.process("Resources/registry.json")],
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "TermXCoreTests",
            dependencies: ["TermXCore", "TermXShellLang", "TetherShellLang", "TermXCommands", "TetherCommands"]
        )
    ]
)
