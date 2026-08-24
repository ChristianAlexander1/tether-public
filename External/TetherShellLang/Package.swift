// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TetherShellLang",
    products: [
        .library(name: "TetherShellLang", targets: ["TetherShellLang"])
    ],
    targets: [
        .target(
            name: "TetherShellLang",
            path: "Sources/TetherShellLang"
        ),
        .testTarget(
            name: "TetherShellLangTests",
            dependencies: ["TetherShellLang"],
            path: "Tests/TetherShellLangTests",
            resources: [.copy("fixtures")]
        )
    ]
)
