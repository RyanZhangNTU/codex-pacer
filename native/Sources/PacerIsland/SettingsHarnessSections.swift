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

    private var provider: AgentProvider { descriptor.id }

    var body: some View {
        MainCard(title: L10n.text("main.section.status")) {
            dataRow
            if let connection = model.harnessAccount(provider) {
                HarnessAccountRow(connection: connection)
            }
        }
        if let connection = model.harnessAccount(provider) {
            HarnessCreditsCard(connection: connection, settings: model.creditSettings(provider), now: model.now)
        }
        // While the ring needs steps or has a problem, its card stands alone;
        // ready or off, it is one row like any other service's ring.
        let guideOpen = descriptor.progressConnector && ProgressGuideRows.opens(ProgressGuideRows.guide(model, provider, isOn: showsProgress))
        MainCard(title: L10n.text("main.section.display")) {
            if descriptor.progressConnector {
                ProgressGuideRows(model: model, provider: provider, isOn: $showsProgress)
            } else if descriptor.hasTaskProgress {
                CardToggle(title: L10n.text("main.claude.ring"), isOn: $showsProgress)
            }
            if !guideOpen, descriptor.reportsAccountCredits { turnCredits }
        }
        if guideOpen, descriptor.reportsAccountCredits {
            MainCard { turnCredits }
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
        case .missing where model.providerDetected(provider): (.secondary, "harness.data.missing", "harness.missing")
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

    private var turnCredits: some View {
        CardToggle(title: L10n.text("harness.turn_credits"), info: L10n.text("main.info.harness_turn_credits"), isOn: $showsTurnCredits)
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
}

/// Sign-in reads as a status with the plan; a button appears only when
/// signing in is needed. Refresh, switching and signing out wait in the
/// row's menu, as on Claude's page.
private struct HarnessAccountRow: View {
    @ObservedObject var connection: HarnessAccountConnection

    var body: some View {
        let reading = connection.reading
        // Reading with nothing to show yet; signed in, amber when the last read
        // failed (the reason goes under the row); or signed out.
        let failed = connection.signedIn && connection.state == .unavailable
        let (tint, key): (Color, String) =
            connection.busy && reading == nil ? (.secondary, "harness.account.reading") :
            connection.signedIn ? (failed ? MainPalette.attention : MainPalette.positive, "harness.account.signed_in") :
            (MainPalette.attention, "harness.account.signed_out")
        let state = [L10n.text(key), key == "harness.account.signed_in" ? reading?.plan : nil].compactMap { $0 }.joined(separator: " · ")
        return CardStatusRow(title: L10n.text("harness.account_row"), state: state, tint: tint, help: connection.siteHost,
                             detail: failed ? L10n.text("harness.account.unavailable") : nil) {
            Group {
                if !connection.signedIn {
                    Button(L10n.text("welcome.module.sign_in")) { connection.connect() }.buttonStyle(.mainProminent)
                } else {
                    Menu {
                        Button(L10n.text("common.refresh")) { connection.refresh() }
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

/// The credits block: the 104 pt dial beside its lines, then the breakdown
/// by how each group behaves behind ⓘ. The lines run to the card's edge, as
/// the breakdown below them does.
private struct HarnessCreditsCard: View {
    @ObservedObject var connection: HarnessAccountConnection
    let settings: HarnessCreditsSettings
    let now: Date
    @State private var showsInfo = false
    @Environment(\.colorScheme) private var colorScheme
    /// The darker shade on a light page, so the ring and plan keep their contrast.
    private var tint: Color { connection.provider.shade(light: colorScheme == .light) }

    var body: some View {
        if let presentation = HarnessCreditsPresentation(credits: connection.credits, settings: settings, now: now) {
            MainCard(title: L10n.text("harness.credits")) {
                HStack(alignment: .center, spacing: 20) {
                    CreditsDial(dial: presentation.dial, tint: tint, size: 104, stale: connection.state == .unavailable, island: false)
                    CreditsLines(presentation: presentation, tint: tint, island: false)
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
            }
        }
    }
}
