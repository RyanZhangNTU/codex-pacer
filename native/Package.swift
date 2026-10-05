// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexPacerIsland",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPacerIsland", targets: ["PacerIsland"]),
               .executable(name: "PacerRelaunch", targets: ["PacerRelaunch"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "PacerCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PacerRelaunch"),
        .executableTarget(name: "PacerIsland", dependencies: ["PacerCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PacerCoreTests", dependencies: ["PacerCore"]),
        .testTarget(name: "PacerIslandTests", dependencies: ["PacerIsland", "PacerCore"])
    ]
)
