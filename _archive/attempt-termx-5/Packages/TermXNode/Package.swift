// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "TermXNode", platforms: [.iOS(.v16)], products: [.library(name: "TermXNode", targets: ["TermXNode"])], dependencies: [.package(path: "../TermXClaude")], targets: [.target(name: "TermXNode", dependencies: ["TermXClaude"], path: "Sources/TermXNode"), .testTarget(name: "TermXNodeTests", dependencies: ["TermXNode"])])
