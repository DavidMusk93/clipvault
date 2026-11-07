// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The inkstone engine is a sibling checkout. Its static library is linked in
// only when it exists, so a machine without the engine still builds ClipVault
// (the shadow path is compiled out).
let envLibDir: String? = ProcessInfo.processInfo.environment["INKSTONE_LIB_DIR"]
let homeDevLibDir = NSHomeDirectory() + "/dev/inkstone/target/release"
let siblingLibDir = NSHomeDirectory() + "/Documents/projects/inkstone/target/release"

var inkstoneLibDir = ""
for candidate in [envLibDir, homeDevLibDir, siblingLibDir] {
    guard let candidate else { continue }
    if FileManager.default.fileExists(atPath: candidate + "/libinkstone_ffi.a") {
        inkstoneLibDir = candidate
        break
    }
}
if inkstoneLibDir.isEmpty { inkstoneLibDir = envLibDir ?? homeDevLibDir }
let hasInkstone = FileManager.default.fileExists(atPath: inkstoneLibDir + "/libinkstone_ffi.a")

var serverSwiftSettings: [SwiftSetting] = []
var ffiLinkerSettings: [LinkerSetting] = []
if hasInkstone {
    serverSwiftSettings.append(.define("INKSTONE"))
    // Link the archive by explicit path: `-linkstone_ffi` resolves to the
    // .dylib and bakes a build-directory path into the app, which breaks a
    // launchd-started binary and hangs dyld when the library is rebuilt.
    ffiLinkerSettings.append(.unsafeFlags([
        "-L\(inkstoneLibDir)",
        "\(inkstoneLibDir)/libinkstone_ffi.a",
    ]))
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
