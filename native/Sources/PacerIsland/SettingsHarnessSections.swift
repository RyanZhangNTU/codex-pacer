import AppKit
import PacerCore
import PacerMacSupport
import SwiftUI

/// A local module's page below its header, laid out like Claude's: what is
/// found and signed in, what the panel shows, then the data folder folded
/// away. Everything a module has comes from its registry entry.
struct SettingsHarnessSections: View {
    @ObservedObject var model: IslandModel
    let descriptor: HarnessDescriptor
    @Binding var showsProgress: Bool
    @Binding var showsTurnCredits: Bool
    @Binding var dataFolder: String
    let commitDataFolder: () -> Void
    @State private var locationsExpanded = false
    @State private var connectorOpenFailed = false

    private var provider: AgentProvider { descriptor.id }

    var body: some View {
        MainCard(title: L10n.text("main.section.status")) {
            dataRow
            if let connection = model.harnessAccount(provider) {
                HarnessAccountRow(connection: connection, usageGuide: descriptor.usageGuide)
            }
        }
        if let connection = model.harnessAccount(provider) {
            HarnessCreditsCard(connection: connection, settings: model.creditSettings(provider), usageGuide: descriptor.usageGuide, now: model.now)
        }
        MainCard(title: L10n.text("main.section.display")) {
            if descriptor.hasTaskProgress { progressRow }
            if descriptor.reportsAccountCredits {
                CardToggle(title: L10n.text("harness.turn_credits"), info: L10n.text("main.info.harness_turn_credits"), isOn: $showsTurnCredits)
            }
        }
        MainCard {
            CardDisclosure(title: L10n.text("provider.custom_locations"),
                summary: dataFolder.isEmpty ? L10n.text("settings.auto_discovery") : L10n.text("main.location.custom"),
                isExpanded: $locationsExpanded)
            if locationsExpanded {
                CardPathField(title: L10n.text("harness.data_folder"), text: $dataFolder,
                    prompt: defaultFolder, commit: commitDataFolder, choose: chooseFolder)
            }
        }
    }

    /// Found or not; a rescan only while it is not found or not readable.
    private var dataRow: some View {
        let status = model.localHarnessStatus(provider)
        let (tint, key, detail): (Color, String, String?) = switch status {
        case .ready: (MainPalette.positive, "harness.data.found", nil)
        case .missing where model.providerDetected(provider): (.secondary, "harness.data.found", "harness.missing")
        case .incompatible: (MainPalette.attention, "harness.data.found", "harness.incompatible")
        case .unavailable: (MainPalette.attention, "harness.data.found", "harness.unavailable")
        case nil where model.providerDetected(provider): (.secondary, "provider.state.searching", nil)
        default: (MainPalette.attention, "harness.data.missing", nil)
        }
        return CardStatusRow(title: L10n.text("harness.data"), state: L10n.text(key), tint: tint,
                             help: model.localHarnessHome(provider)?.path, detail: detail.map { L10n.text($0) }) {
            // Searching needs no button; a folder not found or not readable does.
            if status != .ready, status != nil || !model.providerDetected(provider) {
                Button(L10n.text("settings.rescan")) { model.refreshLocalHarness(provider) }.buttonStyle(.main)
            }
        }
    }

    private var progressRow: some View {
        let state = model.localHarnessProgressStatuses[provider]
        let needsTrust = showsProgress && descriptor.progressConnector && state?.connection == .needsTrust
        return Group {
            ProgressRingToggle(info: L10n.text(provider.rawValue + ".progress_ring_help"), isOn: $showsProgress,
                status: progressState(state), canRetry: [.missingHome, .conflict, .failed].contains(state?.setup) || state?.connection == .missing,
                retry: { model.syncLocalHarnessProgress(force: provider) },
                secondaryTitle: needsTrust ? L10n.text("harness.progress_state.open_connectors") : nil,
                secondaryAction: { Task { connectorOpenFailed = !(await MacLocalHarnessApplication.openProgressConnectors(provider: provider)) } })
            if connectorOpenFailed, needsTrust { CardRow(title: L10n.text("harness.progress_state.open_failed")) }
        }
    }

    private var defaultFolder: String {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }) else { return "" }
        return "~/" + definition.home
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { dataFolder = url.path; commitDataFolder() }
    }

    private func progressState(_ state: LocalHarnessProgressSetup.State?) -> String? {
        let key: String? = switch state?.setup {
        case .settingUp: "setting_up"
        case .configured: showsProgress ? connectionKey(state?.connection) : nil
        case .missingHome: "missing_home"
        case .conflict: "conflict"
        case .failed: showsProgress ? "failed" : "cleanup_failed"
        case nil: nil
        }
        return key.map { L10n.text("harness.progress_state." + $0) }
    }

    private func connectionKey(_ connection: LocalHarnessProgressConnection?) -> String {
        switch connection {
        case .needsTrust: "needs_trust"
        case .trusted: "trusted"
        case .disabled: "disabled"
        case .toolDisabled: "tool_disabled"
        case .missing: "missing"
        case .unknown: "unknown"
        case nil: "configured"
        }
    }
}

/// Sign-in reads as a status with the plan; a button appears only when
/// signing in is needed. Refresh, the usage page, switching and signing
/// out wait in the row's menu, as on Claude's page.
private struct HarnessAccountRow: View {
    @ObservedObject var connection: HarnessAccountConnection
    let usageGuide: URL?

    var body: some View {
        let reading = connection.reading
        let (tint, key): (Color, String) =
            connection.busy && reading == nil ? (.secondary, "harness.account.reading") :
            connection.state == .unavailable ? (MainPalette.attention, "harness.account.unavailable") :
            connection.signedIn && reading != nil ? (MainPalette.positive, "harness.account.signed_in") :
            (MainPalette.attention, "harness.account.signed_out")
        let state = [L10n.text(key), reading?.plan].compactMap { $0 }.joined(separator: " · ")
        return CardStatusRow(title: L10n.text("harness.account_row"), state: state, tint: tint, help: connection.siteHost) {
            Group {
                if !connection.signedIn {
                    Button(L10n.text("welcome.module.sign_in")) { connection.connect() }.buttonStyle(.mainProminent)
                } else {
                    Menu {
                        Button(L10n.text("common.refresh")) { connection.refresh() }
                        if let usageGuide {
                            Button(L10n.text("harness.account_usage_help")) { NSWorkspace.shared.open(usageGuide) }
                        }
                        Divider()
                        Button(L10n.text("harness.account.switch")) { connection.connect(switching: true) }
                        Button(L10n.text("harness.account.sign_out")) { connection.disconnect() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L10n.text("harness.account_row"))
                }
            }
            .disabled(connection.busy)
        }
    }
}

/// The credits block: the 104 pt dial beside its lines, the breakdown by
/// how each group behaves behind ⓘ, then where the service shows usage.
private struct HarnessCreditsCard: View {
    @ObservedObject var connection: HarnessAccountConnection
    let settings: HarnessCreditsSettings
    let usageGuide: URL?
    let now: Date
    @State private var showsInfo = false

    var body: some View {
        if let presentation = HarnessCreditsPresentation(credits: connection.credits, settings: settings, now: now) {
            MainCard(title: L10n.text("harness.credits")) {
                HStack(alignment: .center, spacing: 20) {
                    CreditsDial(dial: presentation.dial, tint: connection.provider.tint, size: 104,
                                stale: connection.state == .unavailable, island: false)
                    CreditsLines(presentation: presentation, tint: connection.provider.tint, island: false)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if !presentation.sections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            Text(L10n.text("credits.details")).font(.system(size: 13))
                            InfoButton(title: L10n.text("credits.details"), isOn: $showsInfo)
                        }
                        if showsInfo {
                            Text(L10n.text("credits.details_info")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        CreditsSections(sections: presentation.sections)
                    }
                    .padding(.vertical, 12)
                }
                if let usageGuide { usageRow(usageGuide) }
            }
        } else if let usageGuide {
            // Signed out, where to check usage still shows.
            MainCard(title: L10n.text("harness.credits")) { usageRow(usageGuide) }
        }
    }

    private func usageRow(_ url: URL) -> some View {
        CardRow(title: L10n.text("harness.account_usage_help")) {
            Link(L10n.text("main.overview.open"), destination: url).font(.system(size: 12.5))
        }
    }
}
