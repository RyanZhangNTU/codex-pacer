import AppKit
import PacerCore
import SwiftUI

/// One version row with where the update stands and its action, then the switch.
struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Binding var automaticallyChecks: Bool
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        MainCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Codex Pacer").font(.system(size: 18, weight: .bold))
                        if let version = Self.version { Text(version).font(.system(size: 18)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .accessibilityElement(children: .combine)
                    UpdateStatus(updater: updater, idleText: idleText)
                }
                Spacer(minLength: 8)
                UpdateActions(updater: updater, showsCheck: true)
            }
            .padding(.vertical, 6)
            CardToggle(title: L10n.text("updates.automatic"), isOn: $automaticallyChecks).disabled(!updater.enabled)
                .help(L10n.text("updates.policy"))
        }
    }

    private var idleText: String? {
        if let release = updater.flow.available { return L10n.text("main.update.available", release.version) }
        if !updater.enabled { return L10n.text("updates.demo_disabled") }
        return updater.lastChecked.map { L10n.text("updates.last_check", L10n.date($0)) }
    }
}

/// A found version at the top of Overview: one click downloads, installs
/// and restarts. Closing it hides this version here; the sidebar keeps a dot.
struct UpdateBanner: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage("updateBannerDismissed") private var dismissed = ""

    var body: some View {
        if let release = updater.flow.available, dismissed != release.version || updater.flow.isBusy {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("main.update.banner", release.version)).font(.system(size: 13, weight: .semibold))
                    UpdateStatus(updater: updater, idleText: L10n.text("main.update.banner_detail"), size: 11.5)
                }
                Spacer(minLength: 8)
                if updater.flow.phase == .idle || updater.flow.phase == .upToDate, let notes = release.notes {
                    Button(L10n.text("main.update.notes")) { NSWorkspace.shared.open(notes) }.buttonStyle(.main)
                }
                UpdateActions(updater: updater, showsCheck: false)
                if !updater.flow.isBusy {
                    Button { dismissed = release.version } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("main.update.later")).accessibilityLabel(L10n.text("main.update.later"))
                }
            }
            // A plain card: amber tints stay for problems that need the user.
            .padding(.horizontal, 16).padding(.vertical, 12)
            .mainCardSurface(radius: 14)
        }
    }
}

/// The line under a title: progress while busy, the result of the last
/// check or install, or the caller's own text when nothing is happening.
private struct UpdateStatus: View {
    @ObservedObject var updater: AppUpdater
    let idleText: String?
    var size: CGFloat = 12.5

    var body: some View {
        let phase = updater.flow.phase
        VStack(alignment: .leading, spacing: 5) {
            if let text = text(phase) {
                Text(text).font(.system(size: size))
                    .foregroundStyle(isFailure(phase) ? MainPalette.attention : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            switch phase {
            case .downloading(let fraction?):
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 240)
            case .downloading(nil), .installing:
                ProgressView().progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 240)
            default:
                EmptyView()
            }
            if isFailure(phase), let page = updater.flow.available?.notes {
                Button(L10n.text("main.update.download_page")) { NSWorkspace.shared.open(page) }
                    .buttonStyle(.link).font(.system(size: size))
            }
        }
    }

    private func isFailure(_ phase: UpdateFlow.Phase) -> Bool {
        if case .failed = phase { true } else { false }
    }

    private func text(_ phase: UpdateFlow.Phase) -> String? {
        switch phase {
        case .idle: idleText
        case .checking: L10n.text("updates.checking")
        case .upToDate: L10n.text("main.update.up_to_date")
        case .downloading(let fraction?): L10n.text("main.update.downloading_percent", String(Int((fraction * 100).rounded(.down))))
        case .downloading(nil): L10n.text("main.update.downloading")
        case .installing: L10n.text("main.update.installing")
        case .failed(let message): L10n.text("main.update.failed", message)
        }
    }
}

/// Cancel while downloading, nothing while installing, otherwise the
/// one-click update when there is one, or (on the version card) a check.
private struct UpdateActions: View {
    @ObservedObject var updater: AppUpdater
    let showsCheck: Bool

    var body: some View {
        switch updater.flow.phase {
        case .downloading:
            Button(L10n.text("common.cancel")) { updater.cancel() }.buttonStyle(.main)
        case .installing:
            EmptyView()
        default:
            if updater.flow.available != nil {
                Button(L10n.text("main.update.install")) { updater.installUpdate() }
                    .buttonStyle(.mainProminent).disabled(updater.enabled && !updater.canCheck)
            } else if showsCheck {
                Button(L10n.text("updates.check")) { updater.checkForUpdates() }
                    .buttonStyle(.main).disabled(!updater.canCheck || updater.flow.isBusy)
            }
        }
    }
}
