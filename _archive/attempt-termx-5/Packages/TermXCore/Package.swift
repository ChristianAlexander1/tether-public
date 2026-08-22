// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "TermXCore", platforms: [.iOS(.v16)], products: [.library(name: "TermXCore", targets: ["TermXCore"])], targets: [.target(name: "TermXCoreC", path: "Sources/TermXCoreC", publicHeadersPath: "."), .target(name: "TermXCore", dependencies: ["TermXCoreC"], path: "Sources/TermXCore"), .testTarget(name: "TermXCoreTests", dependencies: ["TermXCore"])])
