import AppKit
import PacerCore
import PacerMacSupport
import SwiftUI

@MainActor struct HarnessSettingsStatus {
    let text: String
    let detail: String?
    let tint: Color

    init(model: IslandModel, provider: AgentProvider) {
        let keys: (String, String?, Color) = switch model.localHarnessStatus(provider) {
        case .ready: ("harness.ready", nil, .green)
        case .missing where model.providerDetected(provider): ("harness.waiting_for_tasks", "harness.missing", .secondary)
        case .missing: ("harness.not_installed", nil, MainPalette.attention)
        case .incompatible: ("harness.unsupported_format", "harness.incompatible", MainPalette.attention)
        case .unavailable: ("harness.read_failed", "harness.unavailable", MainPalette.attention)
        case nil where !model.providerDetected(provider): ("harness.not_installed", nil, MainPalette.attention)
        case nil: ("provider.state.searching", nil, .secondary)
        }
        text = L10n.text(keys.0)
        detail = keys.1.map { L10n.text($0) }
        tint = keys.2
    }
}

func harnessUsageLines(_ usage: HarnessUsage?) -> [String] {
    guard let usage else { return [] }
    var lines: [String] = []
    if let used = usage.contextUsed, let capacity = usage.contextCapacity {
        lines.append(L10n.text("harness.context", used.formatted(.number.locale(L10n.locale)), capacity.formatted(.number.locale(L10n.locale))))
    }
    if let credits = usage.sessionCredits {
        lines.append(L10n.text("harness.session_credits", credits.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))))
    }
    return lines
}

struct SettingsHarnessSections: View {
    @ObservedObject var model: IslandModel
    let descriptor: HarnessDescriptor
    @Binding var showsProgress: Bool
    @State private var connectorOpenFailed = false

    var body: some View {
        let status = HarnessSettingsStatus(model: model, provider: descriptor.id)
        MainCard(title: L10n.text("main.section.status")) {
            CardStatusRow(title: L10n.text("harness.local_tasks"), state: status.text, tint: status.tint, detail: status.detail) {
                Button(L10n.text("common.refresh")) { model.refreshLocalHarness(descriptor.id) }.buttonStyle(.main)
            }
        }
        if descriptor.reportsAccountCredits {
            WorkBuddyAccountSettings(model: model, connection: model.workBuddyAccount)
        }
        if descriptor.reportsSessionUsage || descriptor.usageGuide != nil {
            let readings = harnessUsageLines(model.localHarnessUsage(descriptor.id))
            MainCard(title: L10n.text("harness.usage")) {
                if readings.isEmpty { CardRow(title: L10n.text("harness.no_usage")) }
                ForEach(readings, id: \.self) { CardRow(title: $0) }
                if let guide = descriptor.usageGuide {
                    CardRow(title: L10n.text("harness.account_usage_help")) {
                        Link(L10n.text("main.overview.open"), destination: guide)
                            .accessibilityLabel(L10n.text("harness.account_usage_help"))
                    }
                }
            }
        }
        if descriptor.hasTaskProgress {
            MainCard(title: L10n.text("main.section.display")) {
                let state = model.localHarnessProgressStatuses[descriptor.id]
                let canOpen = showsProgress && descriptor.id.rawValue == "workbuddy" && state?.connection != nil && state?.connection != .missing
                ProgressRingToggle(info: L10n.text("harness.show_progress_help"), isOn: $showsProgress,
                    status: progressState(state), canRetry: [.missingHome, .conflict, .failed].contains(state?.setup) || state?.connection == .missing,
                    retry: { model.syncLocalHarnessProgress(force: descriptor.id) },
                    secondaryTitle: canOpen ? L10n.text("harness.progress_state.open_connectors") : nil,
                    secondaryAction: { Task { connectorOpenFailed = !(await MacLocalHarnessApplication.openProgressConnectors(provider: descriptor.id)) } })
                if connectorOpenFailed, canOpen { CardRow(title: L10n.text("harness.progress_state.open_failed")) }
            }
        }
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
