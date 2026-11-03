import Foundation

/// One task source as the Connections pane shows it, derived only from the
/// stream statuses the collectors already publish.
public struct ConnectionSource: Equatable, Identifiable {
    public enum State: Int, Comparable, Sendable {
        /// Ordered so problems sort first.
        case retrying, paused, offline, idle, connected
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public let provider: AgentProvider
    public let key: String
    public let name: String
    public let kind: String
    public let state: State
    public let sessions: Int
    public var id: String { provider.rawValue + ":" + key }

    public static let sshPrefix = "remote-ssh-discovered:", controlPrefix = "remote-control:"
    public static let wslPrefix = "wsl:"

    /// Connected sources report their subscribed sessions; a reachable host
    /// without the provider is paused rather than failed. Codex SSH hosts that
    /// could not start are listed as retrying even without a stream status.
    public static func sources(statuses: [AgentProvider: [String: RuntimeStreamStatus]], unavailableSSH: [String],
                        names: [String: String]) -> [ConnectionSource] {
        var result: [ConnectionSource] = []
        for (provider, byKey) in statuses {
            for (key, status) in byKey {
                let state: State = status.connected ? .connected :
                    (key.hasPrefix(controlPrefix) || key.hasPrefix(wslPrefix)) && status.remoteHostOnline == false ? .offline :
                    key.hasPrefix(controlPrefix) && status.waitingForSession ? .idle :
                    status.sourceAvailable == false ? .paused : .retrying
                let name: String, kind: String
                if key == "local" {
                    name = L10n.text("common.local"); kind = provider.displayName
                } else if key == ClaudeCloudProjectState.sourceID {
                    name = L10n.text("connections.kind.claude_cloud"); kind = provider.displayName
                } else if key.hasPrefix(sshPrefix) {
                    name = String(key.dropFirst(sshPrefix.count)); kind = L10n.text("connections.kind.ssh")
                } else if key.hasPrefix(controlPrefix) {
                    name = status.sourceName ?? names[key] ?? L10n.text("connections.kind.remote_control") + " (" + String(key.suffix(8)) + ")"
                    kind = L10n.text("connections.kind.remote_control")
                } else if key.hasPrefix(wslPrefix) {
                    name = status.sourceName ?? names[key] ?? "WSL"; kind = "WSL"
                } else {
                    name = names[key] ?? key; kind = provider.displayName
                }
                result.append(.init(provider: provider, key: key, name: name, kind: kind, state: state,
                    sessions: state == .connected ? status.attachedThreads : 0))
            }
        }
        let listed = Set(result.filter { $0.provider == .codex }.map(\.name))
        for name in unavailableSSH where !listed.contains(name) {
            result.append(.init(provider: .codex, key: sshPrefix + name, name: name, kind: L10n.text("connections.kind.ssh"),
                state: .retrying, sessions: 0))
        }
        let providerOrder = AgentProvider.allCases
        return result.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            if $0.provider != $1.provider {
                return providerOrder.firstIndex(of: $0.provider)! < providerOrder.firstIndex(of: $1.provider)!
            }
            if ($0.key == "local") != ($1.key == "local") { return $0.key == "local" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// One SSH host with the state of each enabled module on it. Codex follows the
/// hosts Codex Desktop connects to and Claude also watches added aliases, but
/// both read the same way here: one row per host, one status per module.
public struct SSHHost: Equatable, Identifiable {
    public enum State: Int, Comparable, Sendable {
        /// Ordered so problems sort first.
        case setupFailed, retrying, configuring, waiting, paused, connected
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        public var isProblem: Bool { self == .setupFailed || self == .retrying }
    }
    public struct Module: Equatable, Sendable {
        public let provider: AgentProvider
        public let state: State
        public let sessions: Int
    }
    public let alias: String
    public let name: String
    public let modules: [Module]
    public var id: String { alias }
    public var claudeSetupFailed: Bool { modules.contains { $0.provider == .claude && $0.state == .setupFailed } }

    /// `codex`/`claude` are nil for a disabled module. Claude setup runs by
    /// itself, so a connected host is only "connected" once its hooks are current.
    public static func hosts(codex: [String: RuntimeStreamStatus]?, unavailableCodex: [String],
                      claude: [String: RuntimeStreamStatus]?, claudeAliases: [String], configured: Set<String>,
                      configuring: Set<String>, failed: Set<String>, names: [String: String] = [:]) -> [SSHHost] {
        let prefix = ConnectionSource.sshPrefix
        var modules: [String: [Module]] = [:]
        if let codex {
            let aliases = codex.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } + unavailableCodex
            for alias in Set(aliases) {
                let status = codex[prefix + alias]
                let state: State = status?.connected == true ? .connected : status?.sourceAvailable == false ? .paused : .retrying
                modules[alias, default: []].append(.init(provider: .codex, state: state, sessions: state == .connected ? status?.attachedThreads ?? 0 : 0))
            }
        }
        if let claude {
            for alias in Set(claudeAliases) {
                let status = claude[prefix + alias]
                let state: State = configuring.contains(alias) ? .configuring :
                    status?.sourceAvailable == false ? .paused :
                    status?.hasConnectionFailure == true ? .retrying :
                    failed.contains(alias) ? .setupFailed :
                    status?.connected == true ? (configured.contains(alias) ? .connected : .configuring) : .waiting
                modules[alias, default: []].append(.init(provider: .claude, state: state, sessions: state == .connected ? status?.attachedThreads ?? 0 : 0))
            }
        }
        return modules.map { SSHHost(alias: $0.key, name: names[$0.key] ?? $0.key, modules: $0.value.sorted { $0.provider == .codex && $1.provider != .codex }) }
            .sorted {
                let lhs = $0.modules.map(\.state).min()!, rhs = $1.modules.map(\.state).min()!
                if lhs.isProblem != rhs.isProblem { return lhs.isProblem }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

/// The summary uses the same effective SSH module states as the host rows,
/// including configured targets whose collector has not published yet.
public struct ConnectionSummary: Equatable {
    public enum State: Equatable, Sendable {
        case disabled, checking, retrying(Int), connecting(Int), paused(Int), offline(Int), idle, connected
    }
    private enum EntryState { case retrying, connecting, paused, offline, idle, connected }
    public let state: State
    public let sources: Int
    public let sessions: Int

    public init(enabledProviders: [AgentProvider], sources: [ConnectionSource], hosts: [SSHHost], overrides: [String: SSHHost.State] = [:]) {
        let enabled = Set(enabledProviders)
        var entries: [String: (state: EntryState, sessions: Int)] = [:]
        for source in sources where enabled.contains(source.provider) {
            // Signing in to claude.ai is optional; without it nothing is wrong.
            if source.key == ClaudeCloudProjectState.sourceID, source.state == .paused { continue }
            let state: EntryState = switch source.state {
            case .retrying: .retrying
            case .paused: .paused
            case .idle: .idle
            case .offline: .offline
            case .connected: .connected
            }
            entries[source.id] = (state, source.sessions)
        }
        for host in hosts {
            for module in host.modules where enabled.contains(module.provider) {
                let id = module.provider.rawValue + ":" + ConnectionSource.sshPrefix + host.alias
                let state: EntryState = switch module.state {
                case .setupFailed, .retrying: .retrying
                case .configuring, .waiting: .connecting
                case .paused: .paused
                case .connected: .connected
                }
                entries[id] = (state, module.sessions)
            }
        }
        for (id, state) in overrides where entries[id] != nil {
            let value: EntryState = switch state {
            case .setupFailed, .retrying: .retrying
            case .configuring, .waiting: .connecting
            case .paused: .paused
            case .connected: .connected
            }
            let sessions: Int
            if case .connected = value { sessions = entries[id]?.sessions ?? 0 } else { sessions = 0 }
            entries[id] = (value, sessions)
        }
        let checking = entries.isEmpty
        // Every enabled module has a local source. One module publishing first
        // must not imply that another module is already connected.
        for provider in enabled {
            let id = provider.rawValue + ":local"
            if entries[id] == nil { entries[id] = (.connecting, 0) }
        }
        self.sources = entries.count
        sessions = entries.values.reduce(0) { $0 + $1.sessions }
        let retrying = entries.values.filter { $0.state == .retrying }.count
        let connecting = entries.values.filter { $0.state == .connecting }.count
        let paused = entries.values.filter { $0.state == .paused }.count
        let offline = entries.values.filter { $0.state == .offline }.count
        let idle = entries.values.contains { $0.state == .idle }
        state = enabled.isEmpty ? .disabled : checking ? .checking :
            retrying > 0 ? .retrying(retrying) : connecting > 0 ? .connecting(connecting) :
            paused > 0 ? .paused(paused) : offline > 0 ? .offline(offline) : idle ? .idle : .connected
    }
}

