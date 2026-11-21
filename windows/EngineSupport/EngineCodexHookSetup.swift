import Foundation
import PacerCore

/// Codex task tracking as Settings and the collapsed bar show it (`CodexHookStatus`).
struct EngineCodexHooks: Codable, Equatable, Sendable {
    /// `off`, `settingUp`, `notInstalled`, `needsApproval`, `running`, `notRunning`, `needsCodexUpdate` or `installFailed`.
    let state: String
    /// For `needsApproval`: how many of Pacer's hooks the user still has to allow in Codex.
    var pending: Int?
    /// For `needsApproval` and `needsCodexUpdate`: Codex Desktop is installed, to open
    /// its settings (`codex://settings`) or itself, which offers its own update.
    var opensSettings: Bool?

    static let settingUp = EngineCodexHooks(state: "settingUp")
    init(state: String, pending: Int? = nil) { self.state = state; self.pending = pending }
    init(_ status: CodexHookStatus) {
        switch status {
        case .off: self.init(state: "off")
        case .notInstalled: self.init(state: "notInstalled")
        case .needsApproval(let count): self.init(state: "needsApproval", pending: count)
        case .running: self.init(state: "running")
        case .notRunning: self.init(state: "notRunning")
        case .needsCodexUpdate: self.init(state: "needsCodexUpdate")
        case .installFailed: self.init(state: "installFailed")
        }
    }
}

/// Installs, refreshes or removes Pacer's Codex hooks for one Codex home:
/// PacerInstallerHooks prepares the bundled Python, the wrapped program and the
/// fixed launcher; `CodexHookSetup` installs the plugin through Codex itself.
struct EngineCodexHookServices: Sendable {
    var apply: @Sendable (_ home: URL, _ executable: String, _ enabled: Bool) async -> CodexHookSetupResult
    /// The trust state alone, while the user approves Pacer's hooks in Codex.
    var trust: @Sendable (_ home: URL, _ executable: String) async -> [String]?
    /// Marks the one notice asking to allow Pacer's hooks in Codex as sent; nil sends none.
    /// The Mac keeps the same fact in its `codexHooksApprovalNotified` preference.
    var noticeMarker: URL? = nil
    /// Whether Codex Desktop is installed, so Settings can open its settings with the guide.
    var opensSettings: @Sendable () -> Bool = { false }

    static func live(runtimeRoot: URL) -> Self {
        Self(apply: { home, executable, enabled in
            let unknown = CodexHookSetupResult(supportsHooks: nil, installed: nil, trust: nil)
            if enabled {
                guard let data = await EngineInstallerHooks.run(["--prepare-codex-hook", runtimeRoot.path, home.path], runtimeRoot: runtimeRoot),
                      let reply = try? JSONDecoder().decode([String: String].self, from: data), let path = reply["launcher"],
                      WindowsCodexHookLauncher.samePath(path, WindowsCodexHookLauncher.launcher(home: home)) else { return unknown }
            }
            guard let cli = CodexClient.findExecutable(customPath: executable) else { return unknown }
            let client = CodexClient(executable: cli, home: home, timeout: 10)
            let result = await CodexHookSetup.apply(home: home, enabled: enabled, launcher: WindowsCodexHookLauncher(),
                                                    storage: WindowsLocalProfileStorage(), client: client)
            await client.shutdown()
            return result
        }, trust: { home, executable in
            guard let cli = CodexClient.findExecutable(customPath: executable) else { return nil }
            let client = CodexClient(executable: cli, home: home, timeout: 10)
            let trust = await CodexHookSetup.trust(client: client)
            await client.shutdown()
            return trust
        }, noticeMarker: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacer/Notifications/codex-hooks-approval-v1"),
        opensSettings: { !WindowsCodexExecutableDiscovery.packageLocations().isEmpty })
    }
}

/// Runs PacerInstallerHooks next to the engine, which owns the bundled Python
/// runtime and the Windows hook bootstrap the engine cannot load itself.
enum EngineInstallerHooks {
    /// Refuses a runtime root inside the installation, which an update replaces.
    static func run(_ arguments: [String], runtimeRoot: URL, timeout: Double = 8) async -> Data? {
        let engine = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let install = engine.deletingLastPathComponent().deletingLastPathComponent().path.lowercased()
        let root = runtimeRoot.path.lowercased()
        guard root != install, !root.hasPrefix(install + "/") else { return nil }
        let helper = engine.deletingLastPathComponent().appendingPathComponent("PacerInstallerHooks.exe")
        return await WindowsSubprocess.capture(executable: helper, arguments: arguments, timeout: timeout, limit: 8192)
    }
}
