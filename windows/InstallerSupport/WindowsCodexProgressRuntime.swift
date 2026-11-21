import Foundation
import PacerCore
import PacerEngineSupport

public struct WindowsCodexProgressRuntime {
    private let paths: WindowsCodexProgressPaths
    private let runtime: WindowsClaudeRuntimeStore

    public init(root: URL) {
        paths = .init(root: root)
        runtime = .init(codexProgressRoot: root)
    }

    /// - Parameter stablePath: one path across reporter updates, for local
    ///   harnesses such as WorkBuddy that trust a command by its path; Codex
    ///   gets a new path with each reporter.
    public func prepare(home: URL, package: URL, stablePath: Bool = false) throws -> CodexProgressCommand {
        guard let resource = Bundle.module.url(forResource: "pacer-codex-progress", withExtension: "py") else {
            throw WindowsClaudeRuntimeStore.Failure.invalidRuntime
        }
        let script = try Data(contentsOf: resource)
        let python = try runtime.withLock { try runtime.ensure(package: package, home: home, progressReporter: script, stablePath: stablePath) }
        return paths.command(python: python, home: home)
    }

    /// Stop cached reporters and remove only our registration in each recorded
    /// profile. A running Codex session may still have the private runtime open.
    public func unregister(homes explicit: [URL], executable: String, checkOnly: Bool) async throws {
        var failed = false
        let homes: [URL]
        do { homes = try runtime.withLock { try runtime.homes(including: explicit) } }
        catch { homes = explicit; failed = true }
        let paths = paths
        for home in homes where CodexProgressSetup.wasConfigured(in: home) || WindowsDurableProgressSetup.wasConfigured(in: home) || Self.hasHooks(home) {
            let status = await CodexProgressSetup.apply(home: home, reporter: nil, storage: WindowsLocalProfileStorage(), checkOnly: checkOnly, owns: {
                paths.owns($0, home: home) || $0.isNative(named: "PacerEngine.exe", home: home)
            }) {
                (CodexClient.findExecutable(customPath: executable) ?? CodexClient.findExecutable()).map {
                    CodexClient(executable: $0, home: home, timeout: 3)
                }
            }
            let removedDurable = await WindowsDurableProgressSetup.apply(home: home, reporter: nil, checkOnly: checkOnly, fallbackExecutable: executable)
            let removedHooks = await Self.removeHooks(home: home, executable: executable, checkOnly: checkOnly)
            if status != nil || !removedDurable || !removedHooks { failed = true }
        }
        if failed { throw WindowsClaudeRuntimeStore.Failure.referenced }
    }

    /// Pacer's Codex hook plugin, by its owned marketplace folder.
    static func hasHooks(_ home: URL) -> Bool {
        FileManager.default.fileExists(atPath: CodexHookPlugin.Layout(home: home).root.path)
    }

    /// Uninstalls Pacer's Codex hook plugin and its launcher; a check only
    /// confirms Pacer still owns what it would remove.
    static func removeHooks(home: URL, executable: String, checkOnly: Bool) async -> Bool {
        guard hasHooks(home) else { return true }
        let layout = CodexHookPlugin.Layout(home: home), storage = WindowsLocalProfileStorage()
        if checkOnly {
            guard (try? storage.validate(layout.owner)) != nil, (try? storage.read(layout.owner)) == CodexHookPlugin.ownerMarker else { return false }
            return true
        }
        guard let cli = CodexClient.findExecutable(customPath: executable) ?? CodexClient.findExecutable() else { return false }
        let client = CodexClient(executable: cli, home: home, timeout: 10)
        let result = await CodexHookSetup.apply(home: home, enabled: false, launcher: WindowsCodexHookLauncher(), storage: storage, client: client)
        await client.shutdown()
        return result.installed == false
    }
}
