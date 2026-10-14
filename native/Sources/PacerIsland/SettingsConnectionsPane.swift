import PacerCore
import SwiftUI

/// One task source as the Connections pane shows it, derived only from the
/// stream statuses the collectors already publish.
struct ConnectionSource: Equatable, Identifiable {
    enum State: Int, Comparable {
        /// Ordered so problems sort first.
        case retrying, paused, offline, idle, connected
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let provider: AgentProvider
    let key: String
    let name: String
    let kind: String
    let state: State
    let sessions: Int
    var id: String { provider.rawValue + ":" + key }

    static let sshPrefix = "remote-ssh-discovered:", controlPrefix = "remote-control:"

    /// Connected sources report their subscribed sessions; a reachable host
    /// without the provider is paused rather than failed. Codex SSH hosts that
    /// could not start are listed as retrying even without a stream status.
    static func sources(statuses: [AgentProvider: [String: RuntimeStreamStatus]], unavailableSSH: [String],
                        names: [String: String]) -> [ConnectionSource] {
        var result: [ConnectionSource] = []
        for (provider, byKey) in statuses {
            for (key, status) in byKey {
                let state: State = status.connected ? .connected :
                    key.hasPrefix(controlPrefix) && status.remoteHostOnline == false ? .offline :
                    key.hasPrefix(controlPrefix) && status.waitingForSession ? .idle :
                    status.sourceAvailable == false ? .paused : .retrying
                let name: String, kind: String
                if key == "local" {
                    name = L10n.text("common.local"); kind = provider.displayName
                } else if key.hasPrefix(sshPrefix) {
                    name = String(key.dropFirst(sshPrefix.count)); kind = L10n.text("connections.kind.ssh")
                } else if key.hasPrefix(controlPrefix) {
                    name = status.sourceName ?? names[key] ?? L10n.text("connections.kind.remote_control") + " (" + String(key.suffix(8)) + ")"
                    kind = L10n.text("connections.kind.remote_control")
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
struct SSHHost: Equatable, Identifiable {
    enum State: Int, Comparable {
        /// Ordered so problems sort first.
        case setupFailed, retrying, configuring, waiting, paused, connected
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        var isProblem: Bool { self == .setupFailed || self == .retrying }
    }
    struct Module: Equatable {
        let provider: AgentProvider
        let state: State
        let sessions: Int
    }
    let alias: String
    let name: String
    let modules: [Module]
    var id: String { alias }
    var claudeSetupFailed: Bool { modules.contains { $0.provider == .claude && $0.state == .setupFailed } }

    /// `codex`/`claude` are nil for a disabled module. Claude setup runs by
    /// itself, so a connected host is only "connected" once its hooks are current.
    static func hosts(codex: [String: RuntimeStreamStatus]?, unavailableCodex: [String],
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
struct ConnectionSummary: Equatable {
    enum State: Equatable {
        case disabled, checking, retrying(Int), connecting(Int), paused(Int), offline(Int), idle, connected
    }
    private enum EntryState { case retrying, connecting, paused, offline, idle, connected }
    let state: State
    let sources: Int
    let sessions: Int

    init(enabledProviders: [AgentProvider], sources: [ConnectionSource], hosts: [SSHHost]) {
        let enabled = Set(enabledProviders)
        var entries: [String: (state: EntryState, sessions: Int)] = [:]
        for source in sources where enabled.contains(source.provider) {
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

/// Connection diagnostics live here because the island shows no connection
/// banners: a summary, every task source with problems first, quota freshness
/// and the data-source switches.
struct SettingsConnectionsPane: View {
    @ObservedObject var model: IslandModel
    @Binding var monitorSSH: Bool
    @Binding var monitorRemoteControl: Bool
    let codexEnabled: Bool
    let claudeEnabled: Bool

    private var sources: [ConnectionSource] {
        let names = Dictionary(model.activities.compactMap { activity in
            activity.sourceHostID.flatMap { id in activity.sourceHost.map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        return ConnectionSource.sources(
            statuses: Dictionary(uniqueKeysWithValues: model.enabledProviders.map { ($0, model.providerStreamStatuses($0)) }),
            unavailableSSH: model.enabledProviders.contains(.codex) ? model.unavailableSSH : [], names: names)
    }

    private var hosts: [SSHHost] {
        guard model.monitorsSSH else { return [] }
        let prefix = ConnectionSource.sshPrefix, targets = model.claudeRemoteTargets
        func aliases<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
            Set(ids.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        }
        return SSHHost.hosts(
            codex: model.isModuleEnabled(.codex) ? model.providerStreamStatuses(.codex) : nil, unavailableCodex: model.unavailableSSH,
            claude: model.isModuleEnabled(.claude) ? model.providerStreamStatuses(.claude) : nil, claudeAliases: targets.map(\.alias),
            configured: Set(targets.filter { model.claudeRemoteConfigured($0) }.map(\.alias)),
            configuring: aliases(model.configuringClaudeHosts), failed: aliases(model.claudeRemoteSetupFailures.keys),
            names: Dictionary(targets.map { ($0.alias, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        let sources = sources, hosts = hosts
        Section { summary(ConnectionSummary(enabledProviders: model.enabledProviders, sources: sources, hosts: hosts)) }
        Section(L10n.text("connections.section.tasks")) {
            ForEach(sources.filter { !$0.key.hasPrefix(ConnectionSource.sshPrefix) }) { source in sourceRow(source) }
            Toggle(L10n.text("settings.monitor_remote_control"), isOn: $monitorRemoteControl)
                .disabled(!codexEnabled)
                .help(L10n.text("settings.remote_control_help"))
        }
        Section(L10n.text("connections.section.ssh")) {
            Toggle(L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
                .disabled(!codexEnabled && !claudeEnabled)
            ForEach(hosts) { host in hostRow(host) }
        }
        if !model.enabledProviders.isEmpty {
            Section(L10n.text("layout.group.quota")) {
                ForEach(model.enabledProviders, id: \.self) { provider in quotaRow(provider) }
            }
        }
    }

    private func summary(_ summary: ConnectionSummary) -> some View {
        let (symbol, tint, title): (String, Color, String) = switch summary.state {
        case .disabled: ("power", .secondary, L10n.text("provider.none_enabled"))
        case .checking: ("ellipsis", .secondary, L10n.text("connections.summary.checking"))
        case .retrying(let count): ("arrow.clockwise", .orange,
            L10n.text(count == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying", count))
        case .connecting(let count): ("ellipsis", .secondary,
            L10n.text(count == 1 ? "connections.summary.connecting_one" : "connections.summary.connecting", count))
        case .paused(let count): ("pause", .secondary,
            L10n.text(count == 1 ? "connections.summary.paused_one" : "connections.summary.paused", count))
        case .offline(let count): ("network.slash", .secondary,
            L10n.text(count == 1 ? "connections.summary.offline_one" : "connections.summary.offline", count))
        case .idle: ("ellipsis", .secondary, L10n.text("connections.summary.idle"))
        case .connected: ("checkmark", .green, L10n.text("connections.summary.ok"))
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if summary.sources > 0 {
                    Text(L10n.text("connections.summary.detail", summary.sources, summary.sessions))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if case .retrying = summary.state {
                Button(L10n.text("connections.retry")) { retryAll() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func retryAll() {
        model.refreshTaskSources()
        for host in hosts where host.claudeSetupFailed { retrySetup(host) }
    }
    private func retrySetup(_ host: SSHHost) {
        Task { _ = await model.configureClaudeRemote(targetID: ConnectionSource.sshPrefix + host.alias) }
    }

    private func sourceRow(_ source: ConnectionSource) -> some View {
        let (tint, state): (Color, String) = switch source.state {
        case .connected: (.green, L10n.text("connections.state.connected"))
        case .retrying: (.orange, L10n.text("connections.state.retrying"))
        case .paused: (.secondary, L10n.text("connections.state.paused", source.provider.displayName))
        case .idle: (.secondary, L10n.text("connections.state.idle"))
        case .offline: (.secondary, L10n.text("connections.state.offline"))
        }
        return HStack(spacing: 10) {
            ProviderTile(provider: source.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).lineLimit(1).truncationMode(.middle).help(source.name)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text((source.kind == source.name ? "" : source.kind + " · ") + state)
                        .foregroundStyle(source.state == .retrying ? Color.orange : Color.secondary)
                }.font(.system(size: 11))
            }
            Spacer(minLength: 8)
            if source.state == .connected {
                Text(L10n.text(source.sessions == 1 ? "connections.sessions_one" : "connections.sessions", source.sessions))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func hostRow(_ host: SSHHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).lineLimit(1).truncationMode(.middle).help(host.name)
                HStack(spacing: 14) {
                    ForEach(host.modules, id: \.provider) { module in moduleStatus(module) }
                }.font(.system(size: 11))
            }
            Spacer(minLength: 8)
            if host.claudeSetupFailed {
                Button(L10n.text("connections.retry")) { retrySetup(host) }
                    .help(model.claudeRemoteSetupFailures[ConnectionSource.sshPrefix + host.alias] ?? "")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func moduleStatus(_ module: SSHHost.Module) -> some View {
        let (tint, key): (Color, String) = switch module.state {
        case .connected: (.green, "connections.host.connected")
        case .configuring: (.secondary, "connections.host.configuring")
        case .waiting: (.secondary, "connections.host.waiting")
        case .paused: (.secondary, "connections.host.missing")
        case .retrying: (.orange, "connections.host.retrying")
        case .setupFailed: (.orange, "connections.host.setup_failed")
        }
        var text = module.provider.displayName + " " + L10n.text(key)
        if module.sessions > 0 {
            text += " · " + L10n.text(module.sessions == 1 ? "connections.sessions_one" : "connections.sessions", module.sessions)
        }
        return HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).foregroundStyle(module.state.isProblem ? Color.orange : Color.secondary).monospacedDigit()
        }
    }

    private func quotaRow(_ provider: AgentProvider) -> some View {
        let error = model.providerQuotaError(provider)
        let detail = [model.providerSourceText(provider), model.providerFreshnessText(provider)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            ProviderTile(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(error ?? detail).font(.system(size: 11)).foregroundStyle(error == nil ? Color.secondary : Color.orange)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if provider == .claude, model.claudeConnectionNeeded {
                Button(L10n.text(model.claudeConnectionActionTitleKey)) { model.connectClaudeQuota() }
                    .disabled(model.providerRefreshing(provider))
            } else if error != nil {
                Button(L10n.text("connections.retry")) { model.retryQuotaConnection(for: provider) }
                    .disabled(model.providerRefreshing(provider))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small provider tile matching the sidebar's module icons.
private struct ProviderTile: View {
    let provider: AgentProvider

    var body: some View {
        Image(systemName: provider.glyph).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.72))
            .frame(width: 22, height: 22)
            .background(provider.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}
