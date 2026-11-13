import Foundation
import PacerCore
import PacerEngineSupport

public enum WindowsLocalHarnessProgressCleanup {
    struct Failure: Error {}

    public static func unregister(executable: String, runtimeRoot: String, fixtureRoot: String, checkOnly: Bool) throws {
        let storage = WindowsLocalProfileStorage()
        let paths = WindowsCodexProgressPaths(root: URL(fileURLWithPath: runtimeRoot, isDirectory: true))
        let runtime = WindowsClaudeRuntimeStore(codexProgressRoot: paths.root)
        let recorded = try runtime.withLock { try runtime.homes(including: []) }
        let environment = ProcessInfo.processInfo.environment
        var failed = false
        for definition in HarnessRegistry.localHarnesses where definition.platforms.contains(.windows) {
            guard let config = definition.progressConfigFile else { continue }
            let home = definition.resolveHome(override: environment.first { $0.key.caseInsensitiveCompare(definition.homeEnvironmentKey) == .orderedSame }?.value,
                isAbsolute: { $0.dropFirst().hasPrefix(":\\") || $0.dropFirst().hasPrefix(":/") })
            let homes = fixtureRoot.isEmpty ? Set([home, definition.defaultHome()] + recorded)
                : Set([URL(fileURLWithPath: fixtureRoot, isDirectory: true).appendingPathComponent(definition.home, isDirectory: true)])
            for folder in homes {
                let target = LocalHarnessProgressSetup.Target(home: folder, configFile: config, reporter: executable, enabled: false,
                                                              ruleDirectory: definition.progressRuleDirectory)
                if LocalHarnessProgressSetup.apply(target, storage: storage, checkOnly: checkOnly, matchNativeReporter: true,
                    owns: { paths.ownsLocalHarness($0, arguments: $1, home: $2) }) != nil { failed = true }
            }
        }
        if failed { throw Failure() }
    }
}
