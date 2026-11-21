import AppKit
import PacerCore
import SwiftUI

/// The two steps that keep Codex tasks showing after Codex 26.1117, as the
/// hooks' live status reads them: update Codex, then allow Pacer in Codex.
/// The same states as Windows (`GuideContent.CodexSetupSteps`).
struct CodexSetupSteps: Equatable {
    enum Update: Equatable { case checking, needed, ready }
    enum Allow: Equatable { case waiting, open, manual, done, failed }
    let update: Update
    let allow: Allow
    var done: Bool { allow == .done }

    /// `opensSettings`: Codex Desktop can open its settings, with the guide beside them.
    init(status: CodexHookStatus, opensSettings: Bool) {
        switch status {
        case .needsCodexUpdate: (update, allow) = (.needed, .waiting)
        case .needsApproval: (update, allow) = (.ready, opensSettings ? .open : .manual)
        case .running, .notRunning: (update, allow) = (.ready, .done)
        case .installFailed: (update, allow) = (.ready, .failed)
        case .off, .notInstalled: (update, allow) = (.checking, .waiting)
        }
    }
}

/// The update note puts the reason above the card; the welcome guide's last
/// page titles the card instead. "Update" opens Codex, which shows a ready
/// update itself; how to check by hand waits behind ⓘ while Codex is too old.
struct CodexSetupCard: View {
    @ObservedObject var model: IslandModel
    var welcome = false
    @State private var showsHint = false
    /// Codex's own page, where a computer without Codex Desktop gets it.
    static let codexPage = URL(string: "https://developers.openai.com/codex/app")!

    var body: some View {
        let desktop = model.canOpenCodexSettings
        let steps = CodexSetupSteps(status: model.codexHookStatus, opensSettings: desktop)
        VStack(spacing: 16) {
            if !welcome {
                Text(L10n.text("whats_new.codex_setup.reason")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            MainCard {
                if welcome {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("welcome.codex_setup.title")).font(.system(size: 14, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.text("welcome.codex_setup.reason")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                }
                updateStep(steps, desktop: desktop)
                allowStep(steps)
            }
        }
    }

    private func updateStep(_ steps: CodexSetupSteps, desktop: Bool) -> some View {
        let (badge, detail): (SetupBadge.State, String) = switch steps.update {
        case .checking: (.checking, "whats_new.codex_setup.checking")
        case .needed: (.attention, "whats_new.codex_setup.update_needed")
        case .ready: (.done, "whats_new.codex_setup.update_ready")
        }
        let hint = steps.update == .needed && desktop ? L10n.text("whats_new.codex_setup.update_hint_mac") : nil
        return stepRow(number: 1, title: L10n.text("whats_new.codex_setup.update"), badge: badge, detail: L10n.text(detail), hint: hint) {
            if steps.update == .needed {
                Button(L10n.text("whats_new.codex_setup.update_action")) { openCodex() }
                    .buttonStyle(MainButtonStyle(prominent: true, height: 28)).fixedSize()
            }
        }
    }

    private func allowStep(_ steps: CodexSetupSteps) -> some View {
        let (badge, detail): (SetupBadge.State, String) = switch steps.allow {
        case .waiting: (.number, steps.update == .needed ? "whats_new.codex_setup.allow_waiting" : "whats_new.codex_setup.allow_detail")
        case .open: (.active, "whats_new.codex_setup.allow_detail")
        case .manual: (.active, "whats_new.codex_setup.allow_manual")
        case .done: (.done, "whats_new.codex_setup.done")
        case .failed: (.attention, "whats_new.codex_setup.failed")
        }
        return stepRow(number: 2, title: L10n.text("whats_new.codex_setup.allow"), badge: badge, detail: L10n.text(detail), hint: nil) {
            switch steps.allow {
            case .open:
                Button(L10n.text("codex.hooks.open")) { model.openCodexHooksGuide(screen: NSApp.keyWindow?.screen) }
                    .buttonStyle(MainButtonStyle(prominent: true, height: 28)).fixedSize()
            case .failed:
                Button(L10n.text("connections.retry")) { model.syncCodexHooks(force: true) }
                    .buttonStyle(MainButtonStyle(height: 28)).fixedSize()
            case .waiting, .manual, .done:
                EmptyView()
            }
        }
    }

    private func stepRow<Action: View>(number: Int, title: String, badge: SetupBadge.State, detail: String, hint: String?,
                                       @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                SetupBadge(number: number, state: badge)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        if hint != nil { InfoButton(title: title, isOn: $showsHint) }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 8)
                action()
            }
            if let hint, showsHint { InfoBox(text: hint).padding(.leading, 36) }
        }
        .padding(.vertical, 12)
    }

    /// Codex itself: it checks for its own updates and shows a ready one.
    private func openCodex() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(Self.codexPage)
        }
    }
}

/// A step's number, or a check once it is done, "!" when it needs the user, "…" while checking.
private struct SetupBadge: View {
    enum State { case number, active, checking, done, attention }
    let number: Int
    let state: State
    @Environment(\.pacerAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(ProgressGuideChip.ink(.success))
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
            case .attention:
                // The notice orange is light in dark mode; its mark is dark there, as on the island's badges.
                Circle().fill(ProgressGuideChip.ink(.attention))
                Text("!").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.26, green: 0.15, blue: 0.02) : .white)
            case .active:
                Circle().fill(accent)
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .checking, .number:
                Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                Text(state == .checking ? "…" : "\(number)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
