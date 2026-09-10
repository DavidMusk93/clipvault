// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClipVaultServer",
            targets: ["ClipVaultServer"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClipVaultServer",
            dependencies: [],
            path: "Sources/ClipVault",
            resources: [
                .copy("Archive/Resources/Readability.js")
            ]
        )
    ]
)
