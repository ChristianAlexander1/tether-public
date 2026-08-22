// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "TermXFiles",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TermXFiles", targets: ["TermXFiles"])],
    targets: [.target(name: "TermXFiles"), .testTarget(name: "TermXFilesTests", dependencies: ["TermXFiles"])]
)
