// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermXShellLang",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXShellLang", targets: ["TermXShellLang"])
    ],
    targets: [
        .target(name: "TermXShellLang"),
        .testTarget(name: "TermXShellLangTests", dependencies: ["TermXShellLang"]),
    ],
    swiftLanguageVersions: [.v5]
)
