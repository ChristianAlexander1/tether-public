// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "TermXPython", platforms: [.iOS(.v16)], products: [.library(name: "TermXPython", targets: ["TermXPython"])], targets: [.target(name: "TermXPython", path: "Sources")])
