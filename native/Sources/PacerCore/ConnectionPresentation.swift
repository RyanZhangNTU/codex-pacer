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

    public static let sshPrefix = "remote-ssh-discovered:"
    public static let managedSSHPrefix = "remote-ssh-codex-managed:"
    public static let wslPrefix = "wsl:"

    public static func isManagedSSHSourceID(_ id: String) -> Bool {
        isValidSSHSourceID(id, prefix: managedSSHPrefix)
    }

    public static func isSSHSourceID(_ id: String) -> Bool {
        id.hasPrefix(sshPrefix) || isManagedSSHSourceID(id)
    }

    static func isValidSSHSourceID(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        return String(id.dropFirst(prefix.count)).range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#,
            options: .regularExpression) != nil
    }

    // Failed helpers can be identified by a legacy alias or by their Desktop source ID.
    static func unavailableSSHSourceID(_ value: String) -> String {
        isSSHSourceID(value) ? value : sshPrefix + value
    }

    static func sshName(_ id: String, displayName: String?) -> String {
        if let displayName { return displayName }
        if id.hasPrefix(sshPrefix) { return String(id.dropFirst(sshPrefix.count)) }
        let suffix = id.dropFirst(managedSSHPrefix.count)
        return L10n.text("connections.kind.ssh") + " (" + String(suffix.suffix(8)) + ")"
    }

    /// True when an SSH source's stream failed while its host is reachable
    /// and the provider is available there, or when a monitored SSH source
    /// failed outright (its helper exited, so it has no stream status left):
    /// the compact bar's SSH reminder.
    public static func hasSSHFailure(in statuses: [[String: RuntimeStreamStatus]], unavailable: [String] = []) -> Bool {
        unavailable.contains(where: isSSHSourceID) ||
            statuses.contains { $0.contains { isSSHSourceID($0.key) && $0.value.hasConnectionFailure } }
    }

    /// Connected sources report their subscribed sessions; a reachable host
    /// without the provider is paused rather than failed. Codex SSH hosts that
    /// could not start are listed as retrying even without a stream status.
    public static func sources(statuses: [AgentProvider: [String: RuntimeStreamStatus]], unavailableSSH: [String],
                        names: [String: String]) -> [ConnectionSource] {
        var result: [ConnectionSource] = []
        for (provider, byKey) in statuses {
            for (key, status) in byKey {
                let state: State = status.connected ? .connected :
                    key.hasPrefix(wslPrefix) && status.remoteHostOnline == false ? .offline :
                    status.sourceAvailable == false ? .paused : .retrying
                let name: String, kind: String
                if key == "local" {
                    name = L10n.text("common.local"); kind = provider.displayName
                } else if key == ClaudeCloudProjectState.sourceID {
                    name = L10n.text("connections.kind.claude_cloud"); kind = provider.displayName
                } else if isSSHSourceID(key) {
                    name = sshName(key, displayName: key.hasPrefix(sshPrefix) ? nil : status.sourceName ?? names[key])
                    kind = L10n.text("connections.kind.ssh")
                } else if key.hasPrefix(wslPrefix) {
                    name = status.sourceName ?? names[key] ?? "WSL"; kind = "WSL"
                } else {
                    name = names[key] ?? key; kind = provider.displayName
                }
                result.append(.init(provider: provider, key: key, name: name, kind: kind, state: state,
                    sessions: state == .connected ? status.attachedThreads : 0))
            }
        }
        let listed = Set(result.filter { $0.provider == .codex }.map(\.key))
        for key in Set(unavailableSSH.map(unavailableSSHSourceID)).subtracting(listed) {
            result.append(.init(provider: .codex, key: key, name: sshName(key, displayName: names[key]),
                kind: L10n.text("connections.kind.ssh"), state: .retrying, sessions: 0))
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
    public let id: String
    public let alias: String
    public let name: String
    public let modules: [Module]
    /// Why Claude's request speeds on this host are estimated, while connected
    /// and no exact span has arrived; `.none` hides the note.
    public var claudeTelemetryNote: ClaudeTelemetryConflict = .none
    public var claudeSetupFailed: Bool { modules.contains { $0.provider == .claude && $0.state == .setupFailed } }

    /// `codex`/`claude` are nil for a disabled module. Claude setup runs by
    /// itself, so a connected host is only "connected" once its hooks are current.
    public static func hosts(codex: [String: RuntimeStreamStatus]?, unavailableCodex: [String],
                      claude: [String: RuntimeStreamStatus]?, claudeAliases: [String], claudeIDs: [String: String] = [:],
                      configured: Set<String>,
                      configuring: Set<String>, failed: Set<String>, names: [String: String] = [:],
                      telemetryConflicts: [String: ClaudeTelemetryConflict] = [:]) -> [SSHHost] {
        let prefix = ConnectionSource.sshPrefix
        var modules: [String: [Module]] = [:], notes: [String: ClaudeTelemetryConflict] = [:]
        if let codex {
            let ids = Set(codex.keys.filter(ConnectionSource.isSSHSourceID) + unavailableCodex.map(ConnectionSource.unavailableSSHSourceID))
            for id in ids {
                let status = codex[id]
                let state: State = status?.connected == true ? .connected : status?.sourceAvailable == false ? .paused : .retrying
                modules[id, default: []].append(.init(provider: .codex, state: state, sessions: state == .connected ? status?.attachedThreads ?? 0 : 0))
            }
        }
        if let claude {
            for alias in Set(claudeAliases) {
                // A host added in Desktop keeps its Desktop ID, so Claude joins the Codex row.
                let id = claudeIDs[alias] ?? prefix + alias
                let status = claude[id]
                let state: State = configuring.contains(alias) ? .configuring :
                    status?.sourceAvailable == false ? .paused :
                    status?.hasConnectionFailure == true ? .retrying :
                    failed.contains(alias) ? .setupFailed :
                    status?.connected == true ? (configured.contains(alias) ? .connected : .configuring) : .waiting
                modules[id, default: []].append(.init(provider: .claude, state: state, sessions: state == .connected ? status?.attachedThreads ?? 0 : 0))
                if state == .connected, status?.exactRequestSpans != true, let note = telemetryConflicts[alias] { notes[id] = note }
            }
        }
        let claudeAlias = Dictionary(claudeIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        return modules.map { id, values in
            let discovered = id.hasPrefix(prefix)
            let alias = discovered ? String(id.dropFirst(prefix.count)) : claudeAlias[id] ?? String(id.dropFirst(ConnectionSource.managedSSHPrefix.count))
            let displayName = discovered ? names[alias] : codex?[id]?.sourceName ?? names[id] ?? claudeAlias[id].flatMap { names[$0] }
            var host = SSHHost(id: id, alias: alias, name: ConnectionSource.sshName(id, displayName: displayName),
                modules: values.sorted { $0.provider == .codex && $1.provider != .codex })
            host.claudeTelemetryNote = notes[id] ?? .none
            return host
        }
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
                let id = module.provider.rawValue + ":" + host.id
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

