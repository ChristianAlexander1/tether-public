// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermXUI",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXUI", targets: ["TermXUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(name: "TermXUI", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")], path: "Sources/TermXUI", resources: [.process("Resources")]),
        .testTarget(name: "TermXUITests", dependencies: ["TermXUI", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Tests/TermXUITests")
    ]
)
