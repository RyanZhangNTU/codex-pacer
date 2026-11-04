import PacerCore

/// The compact bar's SSH reminder. Collector snapshots can still name a host
/// that discovery has just dropped, so every source is checked against what
/// the engine monitors at publication time, as the Connections page is.
enum EngineSSHReminder {
    static func raised(codex: [String: RuntimeStreamStatus], codexUnavailable: [String], claude: [String: RuntimeStreamStatus],
                       monitored: (String, AgentProvider) -> Bool) -> Bool {
        ConnectionSource.hasSSHFailure(in: [codex.filter { monitored($0.key, .codex) }, claude.filter { monitored($0.key, .claude) }],
            unavailable: codexUnavailable.filter { monitored($0, .codex) })
    }
}
