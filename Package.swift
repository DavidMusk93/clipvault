// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "clipflow",
            targets: ["ClipFlowCLI"]
        ),
        .library(
            name: "ClipFlowKit",
            targets: ["ClipFlowKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ClipFlowKit",
            dependencies: [],
            path: "ClipFlow"
        ),
        .executableTarget(
            name: "ClipFlowCLI",
            dependencies: ["ClipFlowKit"],
            path: "CLI"
        )
    ]
)
