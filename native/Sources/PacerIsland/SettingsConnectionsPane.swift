import PacerCore
import SwiftUI

/// One task source as the Connections pane shows it, derived only from the
/// stream statuses the collectors already publish.
struct ConnectionSource: Equatable, Identifiable {
    enum State: Int, Comparable {
        /// Ordered so problems sort first.
        case retrying, paused, connected
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let provider: AgentProvider
    let key: String
    let name: String
    let kind: String
    let state: State
    let sessions: Int
    var id: String { provider.rawValue + ":" + key }

    private static let sshPrefix = "remote-ssh-discovered:", controlPrefix = "remote-control:"

    /// Connected sources report their subscribed sessions; a reachable host
    /// without the provider is paused rather than failed. Codex SSH hosts that
    /// could not start are listed as retrying even without a stream status.
    static func sources(statuses: [AgentProvider: [String: RuntimeStreamStatus]], unavailableSSH: [String],
                        names: [String: String]) -> [ConnectionSource] {
        var result: [ConnectionSource] = []
        for (provider, byKey) in statuses {
            for (key, status) in byKey {
                let state: State = status.connected ? .connected : status.sourceAvailable == false ? .paused : .retrying
                let name: String, kind: String
                if key == "local" {
                    name = L10n.text("common.local"); kind = provider.displayName
                } else if key.hasPrefix(sshPrefix) {
                    name = String(key.dropFirst(sshPrefix.count)); kind = L10n.text("connections.kind.ssh")
                } else if key.hasPrefix(controlPrefix) {
                    name = names[key] ?? L10n.text("connections.kind.remote_control"); kind = L10n.text("connections.kind.remote_control")
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

    var body: some View {
        let sources = sources
        Section { summary(sources) }
        if !sources.isEmpty {
            Section(L10n.text("connections.section.tasks")) {
                ForEach(sources) { source in sourceRow(source) }
            }
        }
        if !model.enabledProviders.isEmpty {
            Section(L10n.text("layout.group.quota")) {
                ForEach(model.enabledProviders, id: \.self) { provider in quotaRow(provider) }
            }
        }
        Section {
            Toggle(L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
                .disabled(!codexEnabled && !claudeEnabled)
            Toggle(isOn: $monitorRemoteControl) {
                Text(L10n.text("settings.monitor_remote_control"))
                Text(L10n.text("settings.remote_control_help"))
            }
            .disabled(!codexEnabled)
        } header: {
            Text(L10n.text("settings.data_source"))
        } footer: {
            Text(L10n.text("connections.footer")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ sources: [ConnectionSource]) -> some View {
        let retrying = sources.filter { $0.state == .retrying }.count
        let sessions = sources.reduce(0) { $0 + $1.sessions }
        let (symbol, tint, title): (String, Color, String) =
            model.enabledProviders.isEmpty ? ("power", .secondary, L10n.text("provider.none_enabled")) :
            sources.isEmpty ? ("ellipsis", .secondary, L10n.text("connections.summary.checking")) :
            retrying > 0 ? ("arrow.clockwise", .orange, L10n.text(retrying == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying", retrying)) :
            ("checkmark", .green, L10n.text("connections.summary.ok"))
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !sources.isEmpty {
                    Text(L10n.text("connections.summary.detail", sources.count, sessions))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if retrying > 0 {
                Button(L10n.text("connections.retry")) { model.refreshTaskSources() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func sourceRow(_ source: ConnectionSource) -> some View {
        let (tint, state): (Color, String) = switch source.state {
        case .connected: (.green, L10n.text("connections.state.connected"))
        case .retrying: (.orange, L10n.text("connections.state.retrying"))
        case .paused: (.secondary, L10n.text("connections.state.paused", source.provider.displayName))
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
