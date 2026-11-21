import PacerCore
import SwiftUI

/// Remote: SSH hosts with each module's state, Codex Dot and any other task
/// source, with the overall state in the page's subtitle. The
/// island shows no connection banners, so problems are read here.
struct SettingsConnectionsPane: View {
    @ObservedObject var model: IslandModel
    @Binding var monitorSSH: Bool
    @Binding var monitorDurable: Bool
    let codexEnabled: Bool
    let claudeEnabled: Bool

    private var sources: [ConnectionSource] { Self.sources(model) }
    private var hosts: [SSHHost] { Self.hosts(model) }
    /// Retrying sources and hosts with a problem, for the sidebar dot and Overview.
    static func problemCount(_ model: IslandModel) -> Int {
        let hosts = hosts(model)
        let retrying: Int
        if case .retrying(let count) = ConnectionSummary(enabledProviders: model.enabledProviders, sources: sources(model), hosts: hosts).state {
            retrying = count
        } else {
            retrying = 0
        }
        return max(retrying, hosts.filter { $0.modules.contains { $0.state.isProblem } }.count) + (model.codexHooksNeedUser ? 1 : 0)
    }

    static func sources(_ model: IslandModel) -> [ConnectionSource] {
        let names = Dictionary(model.activities.compactMap { activity in
            activity.sourceHostID.flatMap { id in activity.sourceHost.map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        return ConnectionSource.sources(
            statuses: Dictionary(uniqueKeysWithValues: model.enabledProviders.map { ($0, model.providerStreamStatuses($0)) }),
            unavailableSSH: model.enabledProviders.contains(.codex) ? model.unavailableSSH : [], names: names)
    }

    static func hosts(_ model: IslandModel) -> [SSHHost] {
        guard model.monitorsSSH else { return [] }
        let targets = model.claudeRemoteTargets
        func aliases<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
            let ids = Set(ids)
            return Set(targets.filter { ids.contains($0.id) }.map(\.alias))
        }
        return SSHHost.hosts(
            codex: model.isModuleEnabled(.codex) ? model.providerStreamStatuses(.codex) : nil, unavailableCodex: model.unavailableSSH,
            claude: model.isModuleEnabled(.claude) ? model.providerStreamStatuses(.claude) : nil, claudeAliases: targets.map(\.alias),
            claudeIDs: Dictionary(targets.map { ($0.alias, $0.id) }, uniquingKeysWith: { first, _ in first }),
            configured: Set(targets.filter { model.claudeRemoteConfigured($0) }.map(\.alias)),
            configuring: aliases(model.configuringClaudeHosts), failed: aliases(model.claudeRemoteSetupFailures.keys),
            names: Dictionary(targets.map { ($0.alias, $0.name) }, uniquingKeysWith: { first, _ in first }),
            telemetryConflicts: model.claudeRemoteTelemetryConflicts())
    }

    /// The page's subtitle: the overall state and how many sources it covers.
    static func summaryText(_ model: IslandModel) -> String {
        let summary = ConnectionSummary(enabledProviders: model.enabledProviders, sources: sources(model), hosts: hosts(model))
        let title: String = switch summary.state {
        case .disabled: L10n.text("provider.none_enabled")
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
        let sources = sources, hosts = hosts
        if codexEnabled {
            MainCard(title: "Codex") { codexHooksRow }
        }
        MainCard(title: L10n.text("connections.section.ssh")) {
            CardToggle(title: L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
                .disabled(!codexEnabled && !claudeEnabled)
            ForEach(hosts) { host in hostRow(host) }
        }
        MainCard(title: "Codex Dot") {
            CardToggle(title: L10n.text("settings.monitor_durable"), info: L10n.text("settings.durable_help"), isOn: $monitorDurable)
                .disabled(!codexEnabled)
        }
        let others = sources.filter { !ConnectionSource.isSSHSourceID($0.key) }
        let canRetry = sources.contains(where: { $0.state == .retrying }) || hosts.contains(where: \.claudeSetupFailed)
        if !others.isEmpty || canRetry {
            MainCard(title: L10n.text("connections.section.tasks")) {
                ForEach(others) { source in sourceRow(source) }
                if canRetry {
                    CardRow(title: L10n.text("main.remote.retry_all")) {
                        Button(L10n.text("connections.retry")) { retryAll() }.buttonStyle(.main)
                    }
                }
            }
        }
    }

    /// Local Codex reaches Pacer only through its hooks, which the user allows in Codex once.
    private var codexHooksRow: some View {
        let detail: String, tint: Color, retry: Bool
        switch model.codexHookStatus {
        case .off, .notInstalled: (detail, tint, retry) = (L10n.text("codex.hooks.setting_up"), .secondary, false)
        case .needsApproval: (detail, tint, retry) = (L10n.text("codex.hooks.needs_approval"), .orange, true)
        case .running: (detail, tint, retry) = (L10n.text("codex.hooks.running"), .green, false)
        case .notRunning: (detail, tint, retry) = (L10n.text("codex.hooks.not_running"), .orange, true)
        case .needsCodexUpdate: (detail, tint, retry) = (L10n.text("codex.hooks.needs_update"), .orange, false)
        case .installFailed: (detail, tint, retry) = (L10n.text("codex.hooks.failed"), .orange, true)
        }
        // Allowing happens in Codex Desktop, which opens on its settings with the guide beside it.
        let opensCodex: Bool
        if case .needsApproval = model.codexHookStatus { opensCodex = model.canOpenCodexSettings } else { opensCodex = false }
        return CardRow(title: L10n.text("codex.hooks.title"), detail: detail, info: L10n.text("codex.hooks.info")) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                if opensCodex {
                    Button(L10n.text("codex.hooks.open")) { model.openCodexHooksGuide(screen: NSApp.keyWindow?.screen) }
                        .buttonStyle(MainButtonStyle(prominent: true, height: 28)).fixedSize()
                } else if retry {
                    Button(L10n.text("connections.retry")) { model.syncCodexHooks(force: true) }.buttonStyle(.main)
                }
            }
        }
    }

    private func retryAll() {
        model.refreshTaskSources()
        for host in hosts where host.claudeSetupFailed { retrySetup(host) }
    }
    private func retrySetup(_ host: SSHHost) {
        Task { _ = await model.configureClaudeRemote(targetID: host.id) }
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
        return HStack(spacing: 12) {
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
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(host.modules, id: \.provider) { ProviderTile(provider: $0.provider, size: 18) }
            }
            .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).lineLimit(1).truncationMode(.middle).help(host.name)
                HStack(spacing: 14) {
                    ForEach(host.modules, id: \.provider) { module in moduleStatus(module) }
                }.font(.system(size: 11))
                if let note = SettingsView.claudeTelemetryNote(host.claudeTelemetryNote) {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if host.claudeSetupFailed {
                Button(L10n.text("connections.retry")) { retrySetup(host) }.buttonStyle(.main)
                    .help(model.claudeRemoteSetupFailures[host.id] ?? "")
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
}

/// A small provider tile matching the sidebar's module icons.
private struct ProviderTile: View {
    let provider: AgentProvider
    var size: CGFloat = 22

    var body: some View {
        ProviderAppIcon(provider: provider, size: size)
    }
}
