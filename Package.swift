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
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "ClipFlowKit",
            dependencies: [
                .product(name: "DuckDB", package: "duckdb-swift")
            ],
            path: "ClipFlow"
        ),
        .executableTarget(
            name: "ClipFlowCLI",
            dependencies: ["ClipFlowKit"],
            path: "CLI"
        )
    ]
)
