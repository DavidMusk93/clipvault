// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The notebase engine is a sibling checkout. Its static library is linked in
// only when it exists, so a machine without the engine still builds ClipVault
// (the shadow path is compiled out).
let envLibDir: String? = ProcessInfo.processInfo.environment["NOTEBASE_LIB_DIR"]
let homeDevLibDir = NSHomeDirectory() + "/dev/notebase/target/release"
let siblingLibDir = NSHomeDirectory() + "/Documents/projects/notebase/target/release"

var notebaseLibDir = ""
for candidate in [envLibDir, homeDevLibDir, siblingLibDir] {
    guard let candidate else { continue }
    if FileManager.default.fileExists(atPath: candidate + "/libnotebase_ffi.a") {
        notebaseLibDir = candidate
        break
    }
}
if notebaseLibDir.isEmpty { notebaseLibDir = envLibDir ?? homeDevLibDir }
let hasNotebase = FileManager.default.fileExists(atPath: notebaseLibDir + "/libnotebase_ffi.a")

var serverSwiftSettings: [SwiftSetting] = []
var ffiLinkerSettings: [LinkerSetting] = []
if hasNotebase {
    serverSwiftSettings.append(.define("NOTEBASE"))
    // Link the archive by explicit path: `-lnotebase_ffi` resolves to the
    // .dylib and bakes a build-directory path into the app, which breaks a
    // launchd-started binary and hangs dyld when the library is rebuilt.
    ffiLinkerSettings.append(.unsafeFlags([
        "-L\(notebaseLibDir)",
        "\(notebaseLibDir)/libnotebase_ffi.a",
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
            name: "CNotebase",
            path: "Sources/CNotebase"
        ),
        // UniFFI-generated Swift bindings (regenerate with
        // ./scripts/sync-notebase-bindings.sh).
        .target(
            name: "NotebaseFFI",
            dependencies: ["CNotebase"],
            path: "Sources/NotebaseFFI",
            linkerSettings: ffiLinkerSettings
        ),
        .executableTarget(
            name: "ClipVaultServer",
            dependencies: ["NotebaseFFI"],
            path: "Sources/ClipVault",
            exclude: [],
            resources: [
                .copy("Archive/Resources/Readability.js")
            ],
            swiftSettings: serverSwiftSettings
        )
    ]
)
