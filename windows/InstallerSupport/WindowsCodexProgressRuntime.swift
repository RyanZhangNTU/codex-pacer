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

    public func prepare(home: URL, package: URL) throws -> CodexProgressCommand {
        guard let resource = Bundle.module.url(forResource: "pacer-codex-progress", withExtension: "py") else {
            throw WindowsClaudeRuntimeStore.Failure.invalidRuntime
        }
        let script = try Data(contentsOf: resource)
        let python = try runtime.withLock { try runtime.ensure(package: package, home: home, progressReporter: script) }
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
        for home in homes where CodexProgressSetup.wasConfigured(in: home) || WindowsDurableProgressSetup.wasConfigured(in: home) {
            let status = await CodexProgressSetup.apply(home: home, reporter: nil, storage: WindowsLocalProfileStorage(), checkOnly: checkOnly, owns: {
                paths.owns($0, home: home) || $0.isNative(named: "PacerEngine.exe", home: home)
            }) {
                (CodexClient.findExecutable(customPath: executable) ?? CodexClient.findExecutable()).map {
                    CodexClient(executable: $0, home: home, timeout: 3)
                }
            }
            let removedDurable = await WindowsDurableProgressSetup.apply(home: home, reporter: nil, checkOnly: checkOnly, fallbackExecutable: executable)
            if status != nil || !removedDurable { failed = true }
        }
        if failed { throw WindowsClaudeRuntimeStore.Failure.referenced }
    }
}
