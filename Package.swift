// swift-tools-version: 5.10
import Foundation
import PackageDescription

// The shipping app uses native/Package.swift. Windows selects the shared
// sources until the C phase closes after B5c. P2 wires remote features.
struct SharedCore: Decodable { let sources: [String]; let tests: [String] }
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let shared = try JSONDecoder().decode(SharedCore.self,
    from: Data(contentsOf: root.appendingPathComponent("windows/shared-core.json")))
let zstd = Target.target(name: "CZstd", path: "native/Sources/CZstd", exclude: ["README.md", "LICENSE"],
    cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_NO_TRACE")])
let gzip = Target.target(name: "CGzip", path: "native/Sources/CGzip", exclude: ["README.md", "provenance.json", "vendor/LICENSE"],
    cSettings: [.define("Z_PREFIX"), .define("Z_SOLO")])
#if os(Windows)
let manager = FileManager.default
let coreDirectory = "native/Sources/PacerCore"
let otherCoreFiles = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(coreDirectory).path)
    .filter { $0 != "Resources" && !shared.sources.contains($0) }.map { coreDirectory + "/" + $0 }
let topLevelExcludes = try manager.contentsOfDirectory(atPath: root.path).filter { $0 != "native" && $0 != "windows" }
let windowsExcludes = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("windows").path)
    .filter { $0 != "EngineSupport" && $0 != "Localization" }.map { "windows/" + $0 }
let coreExcludes = topLevelExcludes + otherCoreFiles + [
    "native/Package.swift", "native/Package.resolved", "native/Info.plist", "native/Resources", "native/Tests",
    "native/.build", "native/.swiftpm", "native/Sources/CZstd", "native/Sources/CGzip", "native/Sources/PacerIsland",
    "native/Sources/PacerRelaunch", "native/Sources/PacerMacSupport"
].filter { manager.fileExists(atPath: root.appendingPathComponent($0).path) } + windowsExcludes
let otherTests = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("native/Tests/PacerCoreTests").path)
    .filter { !shared.tests.contains($0) }
let package = Package(name: "CodexPacerPortable", defaultLocalization: "en", products: [
    .library(name: "PacerCore", targets: ["PacerCore"]),
    .executable(name: "PacerEngine", targets: ["PacerEngine"]),
    .executable(name: "PacerInstallerHooks", targets: ["PacerInstallerHooks"]),
    .library(name: "PacerWindowsBridge", type: .dynamic, targets: ["PacerWindowsBridge"])
], dependencies: [.package(url: "https://github.com/swiftlang/swift-subprocess", exact: "1.0.0")], targets: [
    zstd, gzip,
    .systemLibrary(name: "SQLite3", path: "windows/Native/SQLite3"),
    .target(name: "CWindowsSupport", path: "windows/Native/CWindowsSupport", linkerSettings:
        ["bcrypt", "advapi32", "version", "rstrtmgr", "user32", "ws2_32"].map { .linkedLibrary($0) }),
    .target(name: "CryptoKit", dependencies: ["CWindowsSupport"], path: "windows/Native/CryptoKit"),
    .target(name: "PacerCore", dependencies: ["CZstd", "CGzip", "SQLite3", "CryptoKit", "CWindowsSupport",
        .product(name: "Subprocess", package: "swift-subprocess")], path: ".", exclude: coreExcludes,
        sources: shared.sources.map { coreDirectory + "/" + $0 } + ["windows/EngineSupport"],
        resources: [.process("native/Sources/PacerCore/Resources"), .copy("windows/Localization")]),
    .executableTarget(name: "PacerEngine", dependencies: ["PacerCore"], path: "windows/Engine", exclude: ["app.manifest"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "/MANIFEST:EMBED", "-Xlinker",
            "/MANIFESTINPUT:" + root.appendingPathComponent("windows/Engine/app.manifest").path])]),
    .target(name: "PacerWindowsBridge", dependencies: ["PacerCore"], path: "windows/Bridge"),
    .target(name: "WindowsInstallerSupport", dependencies: ["PacerCore"], path: "windows/InstallerSupport",
        linkerSettings: [.linkedLibrary("advapi32")]),
    .executableTarget(name: "PacerInstallerHooks", dependencies: ["WindowsInstallerSupport"], path: "windows/InstallerHooks"),
    .testTarget(name: "PacerPortableTests", dependencies: ["PacerCore"], path: "native/Tests/PacerCoreTests",
        exclude: otherTests, sources: shared.tests),
    .testTarget(name: "PacerEngineTests", dependencies: ["PacerCore", "WindowsInstallerSupport"], path: "windows/Tests/EngineTests")
])
#else
// Mac builds the whole authoritative Core; its shipping targets and dependencies
// remain in native/Package.swift.
let package = Package(name: "CodexPacerPortable", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [.library(name: "PacerCore", targets: ["PacerCore"]),
               .library(name: "PacerMacSupport", targets: ["PacerMacSupport"])], targets: [
        zstd, gzip,
        .target(name: "PacerCore", dependencies: ["CZstd", "CGzip"], path: "native/Sources/PacerCore",
            resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "PacerMacSupport", dependencies: ["PacerCore"], path: "native/Sources/PacerMacSupport"),
        .testTarget(name: "PacerCoreTests", dependencies: ["PacerCore", "PacerMacSupport"], path: "native/Tests/PacerCoreTests")
    ])
#endif
