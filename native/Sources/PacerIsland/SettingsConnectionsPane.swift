import PacerCore
import SwiftUI

/// Remote: other computers only, SSH hosts with each module's state, the
/// overall state in the page's subtitle. What runs on this computer belongs
/// to its module's page. The island shows no connection banners, so problems
/// are read here.
struct SettingsConnectionsPane: View {
    @ObservedObject var model: IslandModel
    @Binding var monitorSSH: Bool
    let codexEnabled: Bool
    let claudeEnabled: Bool

    private var hosts: [SSHHost] { Self.hosts(model) }
    /// Other computers' sources alone; local, Dot and cloud sources are their modules' own.
    private static func hostSources(_ model: IslandModel) -> [ConnectionSource] {
        sources(model).filter { ConnectionSummary.isHost($0.key) }
    }
    /// Hosts with a problem, for the sidebar dot and Overview.
    static func problemCount(_ model: IslandModel) -> Int {
        guard model.monitorsSSH else { return 0 }
        let hosts = hosts(model)
        let retrying: Int
        if case .retrying(let count) = ConnectionSummary(enabledProviders: model.enabledProviders, sources: hostSources(model), hosts: hosts,
                                                          hostsOnly: true).state {
            retrying = count
        } else {
            retrying = 0
        }
        return max(retrying, hosts.filter { $0.modules.contains { $0.state.isProblem } }.count)
    }

    static func sources(_ model: IslandModel) -> [ConnectionSource] {
        let names = Dictionary(model.activities.compactMap { activity in
            activity.sourceHostID.flatMap { id in activity.sourceHost.map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        return ConnectionSource.sources(
            statuses: Dictionary(uniqueKeysWithValues: model.enabledProviders.map { ($0, model.providerStreamStatuses($0)) }),
            unavailableSSH: model.enabledProviders.contains(.codex) ? model.unavailableSSH : [], names: names, monitoring: model.sshMonitoring)
    }

    static func hosts(_ model: IslandModel) -> [SSHHost] {
        guard model.monitorsSSH else { return [] }
        let targets = model.discoveredClaudeTargets
        func aliases<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
            let ids = Set(ids)
            return Set(targets.filter { ids.contains($0.id) }.map(\.alias))
        }
        return SSHHost.hosts(
            codex: model.isModuleEnabled(.codex) ? model.providerStreamStatuses(.codex) : nil, unavailableCodex: model.unavailableSSH,
            claude: model.isModuleEnabled(.claude) ? model.providerStreamStatuses(.claude) : nil, claudeAliases: targets.map(\.alias),
            claudeIDs: Dictionary(targets.map { ($0.alias, $0.id) }, uniquingKeysWith: { first, _ in first }),
            configured: Set(model.claudeRemoteTargets.filter { model.claudeRemoteConfigured($0) }.map(\.alias)),
            configuring: aliases(model.configuringClaudeHosts), failed: aliases(model.claudeRemoteSetupFailures.keys),
            names: Dictionary(targets.map { ($0.alias, $0.name) }, uniquingKeysWith: { first, _ in first }),
            telemetryConflicts: model.claudeRemoteTelemetryConflicts(), codexTargets: model.discoveredCodexTargets, monitoring: model.sshMonitoring)
    }

    /// The page's subtitle: the hosts' overall state and how many it covers;
    /// nothing while SSH monitoring is off, as its switch says.
    static func summaryText(_ model: IslandModel) -> String? {
        guard model.monitorsSSH else { return nil }
        let hosts = hosts(model)
        let summary = ConnectionSummary(enabledProviders: model.enabledProviders, sources: hostSources(model), hosts: hosts,
                                        hostsOnly: true)
        let title: String = switch summary.state {
        case .disabled: L10n.text("provider.none_enabled")
        case .noHosts: L10n.text(hosts.isEmpty ? "connections.summary.no_hosts" : "connections.summary.none_monitored")
        case .checking: L10n.text("connections.summary.checking")
        case .retrying(let count): L10n.text(count == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying", count)
        case .connecting(let count): L10n.text(count == 1 ? "connections.summary.connecting_one" : "connections.summary.connecting", count)
        case .paused(let count): L10n.text(count == 1 ? "connections.summary.paused_one" : "connections.summary.paused", count)
        case .offline(let count): L10n.text(count == 1 ? "connections.summary.offline_one" : "connections.summary.offline", count)
        case .idle: L10n.text("connections.summary.idle")
        case .connected: L10n.text("connections.summary.ok")
        }
        guard summary.sources > 0 else { return title }
        return title + " · " + L10n.text("connections.summary.detail", summary.sources, summary.sessions)
    }

    var body: some View {
        MainCard(title: L10n.text("connections.section.ssh")) {
            CardToggle(title: L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
                .disabled(!codexEnabled && !claudeEnabled)
            ForEach(hosts) { host in hostRow(host) }
        }
    }

    private func retrySetup(_ host: SSHHost) {
        Task { _ = await model.configureClaudeRemote(targetID: host.id) }
    }

    private func hostRow(_ host: SSHHost) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(host.modules, id: \.provider) { ProviderTile(provider: $0.provider, size: 18) }
            }
            .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).lineLimit(1).truncationMode(.middle).help(host.name)
                if host.monitored {
                    HStack(spacing: 14) {
                        ForEach(host.modules, id: \.provider) { module in moduleStatus(module) }
                    }.font(.system(size: 11))
                } else {
                    Text(L10n.text("connections.host.not_monitored")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let note = SettingsView.claudeTelemetryNote(host.claudeTelemetryNote) {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if host.claudeSetupFailed {
                Button(L10n.text("connections.retry")) { retrySetup(host) }.buttonStyle(.main)
                    .help(model.claudeRemoteSetupFailures[host.id] ?? "")
            }
            Toggle(L10n.text("connections.host.monitor", host.name), isOn: Binding(
                get: { !model.sshMonitoring.offIDs.contains(host.id) }, set: { model.setSSHHost(host.id, monitored: $0) }))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(L10n.text("connections.host.monitor", host.name))
        }
        .accessibilityElement(children: .contain)
    }

    private func moduleStatus(_ module: SSHHost.Module) -> some View {
        let (tint, key): (Color, String) = switch module.state {
        case .connected: (.green, "connections.host.connected")
        case .configuring: (.secondary, "connections.host.configuring")
        case .waiting: (.secondary, "connections.host.waiting")
        case .queued: (.secondary, "connections.host.queued")
        case .notMonitored: (.secondary, "connections.host.not_monitored")
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
}

/// A small provider tile matching the sidebar's module icons.
private struct ProviderTile: View {
    let provider: AgentProvider
    var size: CGFloat = 22

    var body: some View {
        ProviderAppIcon(provider: provider, size: size)
    }
}
