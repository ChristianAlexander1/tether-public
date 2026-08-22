// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "TermXLinux", platforms: [.iOS(.v16)], products: [.library(name: "TermXLinux", targets: ["TermXLinux"])], targets: [.target(name: "TermXLinux", path: "Sources")])
