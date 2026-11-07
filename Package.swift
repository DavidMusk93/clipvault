// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The inkstone engine is a sibling checkout. Its static library is linked in
// only when it exists, so a machine without the engine still builds ClipVault
// (the shadow path is compiled out).
let packageDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let inkstoneLibDir = ProcessInfo.processInfo.environment["INKSTONE_LIB_DIR"]
    ?? packageDir.deletingLastPathComponent().appendingPathComponent("inkstone/target/release").path
let hasInkstone = FileManager.default.fileExists(
    atPath: inkstoneLibDir + "/libinkstone_ffi.a"
)

var serverSwiftSettings: [SwiftSetting] = []
var ffiLinkerSettings: [LinkerSetting] = []
if hasInkstone {
    serverSwiftSettings.append(.define("INKSTONE"))
    ffiLinkerSettings.append(.unsafeFlags(["-L\(inkstoneLibDir)", "-linkstone_ffi"]))
}

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
        // C shim for the UniFFI-generated header.
        .systemLibrary(
            name: "CInkstone",
            path: "Sources/CInkstone"
        ),
        // UniFFI-generated Swift bindings (regenerate with
        // ./scripts/sync-inkstone-bindings.sh).
        .target(
            name: "InkstoneFFI",
            dependencies: ["CInkstone"],
            path: "Sources/InkstoneFFI",
            linkerSettings: ffiLinkerSettings
        ),
        .executableTarget(
            name: "ClipVaultServer",
            dependencies: ["InkstoneFFI"],
            path: "Sources/ClipVault",
            exclude: [],
            resources: [
                .copy("Archive/Resources/Readability.js")
            ],
            swiftSettings: serverSwiftSettings
        )
    ]
)
