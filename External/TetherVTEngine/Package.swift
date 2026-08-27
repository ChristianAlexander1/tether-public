// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TetherVTEngine", platforms: [.macOS(.v13), .iOS(.v16)], products: [.library(name: "TetherVTEngine", targets: ["TetherVTEngine"])], targets: [.target(name: "TetherVTEngine"), .testTarget(name: "TetherVTEngineTests", dependencies: ["TetherVTEngine"], resources: [.copy("Fixtures")])])
