// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexPacerIsland",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPacerIsland", targets: ["PacerIsland"])],
    targets: [
        .target(name: "PacerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PacerIsland", dependencies: ["PacerCore"]),
        .testTarget(name: "PacerCoreTests", dependencies: ["PacerCore"])
    ]
)
