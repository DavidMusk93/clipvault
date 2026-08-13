// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClipFlowServer",
            targets: ["ClipFlowServer"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClipFlowServer",
            dependencies: [],
            path: "ClipFlow",
            exclude: ["ClipFlowApp.swift", "ContentView.swift", "ClipFlow.entitlements", "Assets.xcassets", "Preview Assets.xcassets"],
            resources: [
                .copy("Resources/Readability.js")
            ]
        )
    ]
)
