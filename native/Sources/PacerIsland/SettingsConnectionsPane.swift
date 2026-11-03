import PacerCore
import SwiftUI

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
        case .paused: (.secondary, source.key == ClaudeCloudProjectState.sourceID ? L10n.text("connections.state.cloud_signed_out")
            : L10n.text("connections.state.paused", source.provider.displayName))
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
