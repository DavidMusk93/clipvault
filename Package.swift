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
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "ClipFlowServer",
            dependencies: [
                .product(name: "DuckDB", package: "duckdb-swift")
            ],
            path: "ClipFlow",
            exclude: ["ClipFlowApp.swift", "ContentView.swift", "ClipFlow.entitlements", "Assets.xcassets", "Preview Assets.xcassets"]
        )
    ]
)
