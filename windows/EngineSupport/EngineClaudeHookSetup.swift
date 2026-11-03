import Foundation

struct EngineClaudeHookSetup: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case disabled, settingUp, ready, needsSetup, missingHome, failed }
    let state: State
    var hooksConfigured = false, telemetryConfigured = false, statusLineConfigured = false
    var telemetryConflict = false, updateAvailable = false
    var launchMode: String?
    init(_ state: State) { self.state = state }
}

struct EngineClaudeHookServices: Sendable {
    enum Action: Sendable { case ensure, remove }
    var perform: @Sendable (Action, URL) async -> EngineClaudeHookSetup
    static func live(root: URL) -> Self {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("PacerInstallerHooks.exe")
        return Self { action, home in
            let operation = action == .ensure ? "--ensure" : "--uninstall-home"
            guard let data = await WindowsSubprocess.capture(executable: helper, arguments: [operation, home.path, root.path], timeout: 5, limit: 4096) else { return .init(.failed) }
            if action == .remove { return .init(.disabled) }
            return (try? JSONDecoder().decode(EngineClaudeHookSetup.self, from: data)) ?? .init(.failed)
        }
    }
}
