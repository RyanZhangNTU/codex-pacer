// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Both hosts compile the complete authoritative Core directory. Platform IO
// belongs to PacerMacSupport or PacerEngineSupport, never to PacerCore.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let zstd = Target.target(name: "CZstd", path: "native/Sources/CZstd", exclude: ["README.md", "LICENSE"],
    cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_NO_TRACE")])
let gzip = Target.target(name: "CGzip", path: "native/Sources/CGzip", exclude: ["README.md", "provenance.json", "vendor/LICENSE"],
    cSettings: [.define("Z_PREFIX"), .define("Z_SOLO")])
#if os(Windows)
let package = Package(name: "CodexPacerPortable", defaultLocalization: "en", products: [
    .library(name: "PacerCore", targets: ["PacerCore"]),
    .executable(name: "PacerEngine", targets: ["PacerEngine"]),
    .executable(name: "PacerInstallerHooks", targets: ["PacerInstallerHooks"]),
    .library(name: "PacerWindowsBridge", type: .dynamic, targets: ["PacerWindowsBridge"])
], dependencies: [.package(url: "https://github.com/swiftlang/swift-subprocess", exact: "1.0.0")], targets: [
    zstd, gzip,
    .systemLibrary(name: "SQLite3", path: "windows/Native/SQLite3"),
    .target(name: "CWindowsSupport", path: "windows/Native/CWindowsSupport", linkerSettings:
        ["bcrypt", "advapi32", "version", "rstrtmgr", "user32", "ws2_32", "shell32", "ole32", "winhttp"].map { .linkedLibrary($0) }),
    .target(name: "CryptoKit", dependencies: ["CWindowsSupport"], path: "windows/Native/CryptoKit"),
    .target(name: "PacerCore", dependencies: ["CZstd", "CGzip", "SQLite3", "CryptoKit"],
        path: "native/Sources/PacerCore", resources: [.process("Resources")]),
    .target(name: "PacerEngineSupport", dependencies: ["PacerCore", "CryptoKit", "CWindowsSupport",
        .product(name: "Subprocess", package: "swift-subprocess")], path: "windows/EngineSupport",
        resources: [.copy("Resources/Localization"), .copy("Resources/WSL")]),
    .executableTarget(name: "PacerEngine", dependencies: ["PacerEngineSupport"], path: "windows/Engine", exclude: ["app.manifest"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "/MANIFEST:EMBED", "-Xlinker",
            "/MANIFESTINPUT:" + root.appendingPathComponent("windows/Engine/app.manifest").path])]),
    .target(name: "PacerWindowsBridge", dependencies: ["PacerCore", "PacerEngineSupport"], path: "windows/Bridge"),
    .target(name: "WindowsInstallerSupport", dependencies: ["PacerCore", "PacerEngineSupport", "CryptoKit"], path: "windows/InstallerSupport",
        resources: [.process("Resources")],
        linkerSettings: [.linkedLibrary("advapi32")]),
    .executableTarget(name: "PacerInstallerHooks", dependencies: ["WindowsInstallerSupport"], path: "windows/InstallerHooks"),
    .testTarget(name: "PacerCoreTests", dependencies: ["PacerCore", "PacerEngineSupport", "SQLite3"], path: "native/Tests/PacerCoreTests"),
    .testTarget(name: "PacerEngineTests", dependencies: ["PacerCore", "PacerEngineSupport", "WindowsInstallerSupport"], path: "windows/Tests/EngineTests")
])
#else
// The shipping executable and its pinned dependencies remain in native/Package.swift.
let package = Package(name: "CodexPacerPortable", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [.library(name: "PacerCore", targets: ["PacerCore"]),
               .library(name: "PacerMacSupport", targets: ["PacerMacSupport"])], targets: [
        zstd, gzip,
        .target(name: "PacerCore", dependencies: ["CZstd", "CGzip"], path: "native/Sources/PacerCore",
            resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "PacerMacSupport", dependencies: ["PacerCore"], path: "native/Sources/PacerMacSupport"),
        .testTarget(name: "PacerCoreTests", dependencies: ["PacerCore", "PacerMacSupport"], path: "native/Tests/PacerCoreTests"),
        .testTarget(name: "PacerMacSupportTests", dependencies: ["PacerCore", "PacerMacSupport"], path: "native/Tests/PacerMacSupportTests")
    ])
#endif
