// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "TermXUI", platforms: [.iOS(.v16)], products: [.library(name: "TermXUI", targets: ["TermXUI"])], dependencies: [.package(path: "../TermXCore"), .package(path: "../TermXFiles")], targets: [.target(name: "TermXUI", dependencies: ["TermXCore", "TermXFiles"], path: "Sources/TermXUI")])
