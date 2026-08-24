// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TermXNode",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermXNode", targets: ["TermXNode"]),
    ],
    dependencies: [
        .package(path: "../TermXCore"),
        .package(path: "../TermXFiles"),
    ],
    targets: [
        .binaryTarget(
            name: "NodeMobileBinary",
            path: "Vendor/NodeMobile.xcframework"
        ),
        .target(
            name: "NodeMobileBridge",
            dependencies: ["NodeMobileBinary"],
            path: "Sources/NodeMobileBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("NodeMobile"),
            ]
        ),
        .target(
            name: "TermXNode",
            dependencies: [
                "TermXCore",
                "TermXFiles",
                .target(name: "NodeMobileBridge", condition: .when(platforms: [.iOS])),
            ],
            resources: [
                .process("Resources/registry.json"),
                .copy("Resources/shim"),
            ]
        ),
        .testTarget(
            name: "TermXNodeTests",
            dependencies: ["TermXNode", "TermXFiles"]
        ),
    ]
)
