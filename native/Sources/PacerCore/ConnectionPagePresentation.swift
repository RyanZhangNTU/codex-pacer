import Foundation

/// The host supplies stream/setup facts. Ordering, counts and translated
/// connection states use the same tables as the Mac Connections pane.
public struct ConnectionPagePresentation: Codable, Equatable, Sendable {
    public enum Setup: String, Codable, Sendable { case configured, configuring, failed }
    public struct Module: Codable, Equatable, Sendable {
        public let id, key, provider, label, state, tone, sessionsText: String
        public let sessions: Int
        public let retrySetup: Bool
        public let readsQuota: Bool
    }
    public struct Source: Codable, Equatable, Sendable {
        public let id, key, provider, name, kind: String
        public let module: Module
    }
    public struct Host: Codable, Equatable, Sendable {
        public let id, name, kind: String
        public let modules: [Module]
    }
    public let state, title, detail, tone: String
    public let sourceCount, sessionCount: Int
    public let retry: Bool
    public let sources: [Source]
    public let hosts: [Host]

    public init(enabledProviders: [AgentProvider], statuses: [AgentProvider: [String: RuntimeStreamStatus]],
                unavailableSSH: [String] = [], claudeAliases: [String] = [], configured: Set<String> = [],
                configuring: Set<String> = [], failed: Set<String> = [], names: [String: String] = [:],
                setup: [String: Setup] = [:], canRetrySetup: Bool = false, quotaSources: Set<String> = []) {
        let enabled = Set(enabledProviders)
        let streams = statuses.filter { enabled.contains($0.key) }
        let sourceValues = ConnectionSource.sources(statuses: streams, unavailableSSH: unavailableSSH, names: names)
        let ssh = SSHHost.hosts(codex: enabled.contains(.codex) ? streams[.codex] ?? [:] : nil,
            unavailableCodex: enabled.contains(.codex) ? unavailableSSH : [],
            claude: enabled.contains(.claude) ? streams[.claude] ?? [:] : nil, claudeAliases: claudeAliases,
            configured: configured, configuring: configuring, failed: failed, names: names)
        var overrides: [String: SSHHost.State] = [:]
        for source in sourceValues where source.provider == .claude && source.key.hasPrefix(ConnectionSource.wslPrefix) && source.state != .paused {
            if setup[source.key] == .failed && source.state == .connected { overrides[source.id] = .setupFailed }
            else if setup[source.key] == .configuring { overrides[source.id] = .configuring }
        }
        let summary = ConnectionSummary(enabledProviders: enabledProviders, sources: sourceValues, hosts: ssh, overrides: overrides)
        sourceCount = summary.sources; sessionCount = summary.sessions
        detail = summary.sources == 0 ? "" : L10n.text("connections.summary.detail", summary.sources, summary.sessions)
        switch summary.state {
        case .disabled: state = "disabled"; title = L10n.text("provider.none_enabled")
        case .checking: state = "checking"; title = L10n.text("connections.summary.checking")
        case .retrying(let count): state = "retrying"; title = L10n.text(count == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying", count)
        case .connecting(let count): state = "connecting"; title = L10n.text(count == 1 ? "connections.summary.connecting_one" : "connections.summary.connecting", count)
        case .paused(let count): state = "paused"; title = L10n.text(count == 1 ? "connections.summary.paused_one" : "connections.summary.paused", count)
        case .offline(let count): state = "offline"; title = L10n.text(count == 1 ? "connections.summary.offline_one" : "connections.summary.offline", count)
        case .idle: state = "idle"; title = L10n.text("connections.summary.idle")
        case .connected: state = "connected"; title = L10n.text("connections.summary.ok")
        }
        retry = state == "retrying"; tone = retry ? "warning" : state == "connected" ? "success" : "neutral"
        func module(provider: AgentProvider, key: String, state: String, sessions: Int, label: String) -> Module {
            let id = provider.rawValue + ":" + key
            let problem = state == "retrying" || state == "setupFailed"
            return .init(id: id, key: key, provider: provider.rawValue, label: label, state: state,
                tone: problem ? "warning" : state == "connected" ? "success" : "neutral",
                sessionsText: sessions == 0 ? "" : L10n.text(sessions == 1 ? "connections.sessions_one" : "connections.sessions", sessions), sessions: sessions,
                retrySetup: canRetrySetup && provider == .claude && state == "setupFailed", readsQuota: quotaSources.contains(id))
        }
        func sourceModule(_ source: ConnectionSource) -> Module {
            let state: String, label: String
            if source.provider == .claude, let override = overrides[source.id] {
                state = String(describing: override)
                label = L10n.text(override == .setupFailed ? "connections.host.setup_failed" : "connections.host.configuring")
            } else {
                state = String(describing: source.state)
                label = source.state == .paused ? (source.key == ClaudeCloudProjectState.sourceID ? L10n.text("connections.state.cloud_signed_out") :
                    L10n.text("connections.state.paused", source.provider.displayName)) : L10n.text("connections.state." + state)
            }
            return module(provider: source.provider, key: source.key, state: state,
                sessions: overrides[source.id] == nil ? source.sessions : 0, label: label)
        }
        sources = sourceValues.filter { !$0.key.hasPrefix(ConnectionSource.sshPrefix) && !$0.key.hasPrefix(ConnectionSource.wslPrefix) }.map {
            .init(id: $0.id, key: $0.key, provider: $0.provider.rawValue, name: $0.name, kind: $0.kind, module: sourceModule($0))
        }
        var hostValues = ssh.map { host in
            Host(id: ConnectionSource.sshPrefix + host.alias, name: host.name, kind: "SSH", modules: host.modules.map { value in
                let key: String = switch value.state {
                case .connected: "connected"
                case .configuring: "configuring"
                case .waiting: "waiting"
                case .paused: "missing"
                case .retrying: "retrying"
                case .setupFailed: "setup_failed"
                }
                return module(provider: value.provider, key: ConnectionSource.sshPrefix + host.alias,
                    state: String(describing: value.state), sessions: value.sessions, label: L10n.text("connections.host." + key))
            })
        }
        let wsl = Dictionary(grouping: sourceValues.filter { $0.key.hasPrefix(ConnectionSource.wslPrefix) }, by: \.key)
        hostValues += wsl.map { key, values in
            Host(id: key, name: values.first!.name, kind: "WSL", modules: values.sorted {
                (AgentProvider.allCases.firstIndex(of: $0.provider) ?? 0) < (AgentProvider.allCases.firstIndex(of: $1.provider) ?? 0)
            }.map(sourceModule))
        }
        func rank(_ host: Host) -> Int {
            host.modules.map { ["setupFailed": 0, "retrying": 0, "offline": 1, "paused": 2,
                                "configuring": 3, "waiting": 3, "idle": 4, "connected": 5][$0.state] ?? 3 }.min() ?? 3
        }
        hosts = hostValues.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
