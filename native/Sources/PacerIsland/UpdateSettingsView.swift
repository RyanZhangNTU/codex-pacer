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
                    // The panel below says what went wrong and what to do instead.
                    if updater.flow.failure == nil { UpdateStatus(updater: updater, idleText: idleText) }
                }
                Spacer(minLength: 8)
                if updater.flow.failure == nil { UpdateActions(updater: updater, showsCheck: true) }
            }
            .padding(.vertical, 6)
            if let failure = updater.flow.failure { UpdateFailurePanel(updater: updater, failure: failure) }
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
    /// Opens Help & Updates, where the other ways to get Pacer are.
    var showWays: () -> Void = {}
    @AppStorage("updateBannerDismissed") private var dismissed = ""
    /// The failed check this banner was closed for; the next failure brings it back.
    @AppStorage("updateFailureDismissed") private var dismissedFailure = 0.0

    var body: some View {
        if case .check? = updater.flow.failure, let failedAt = updater.flow.checkFailedAt,
           failedAt.timeIntervalSince1970 > dismissedFailure {
            HStack(spacing: 12) {
                Image(systemName: "network.slash").font(.system(size: 18, weight: .medium)).foregroundStyle(MainPalette.attention)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("update.failure.banner_check")).font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("update.failure.banner_check_detail")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L10n.text("update.failure.show_ways"), action: showWays).buttonStyle(.main)
                closeButton { dismissedFailure = failedAt.timeIntervalSince1970 }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .mainCardSurface(radius: 14)
        } else if let release = updater.flow.available, dismissed != release.version || updater.flow.isBusy {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                let downloadFailed = updater.flow.failure == .download(release)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("main.update.banner", release.version)).font(.system(size: 13, weight: .semibold))
                    if downloadFailed {
                        Text(L10n.text("update.failure.banner_download_detail")).font(.system(size: 11.5))
                            .foregroundStyle(MainPalette.attention).fixedSize(horizontal: false, vertical: true)
                    } else {
                        UpdateStatus(updater: updater, idleText: L10n.text("main.update.banner_detail"), size: 11.5)
                    }
                }
                Spacer(minLength: 8)
                if downloadFailed {
                    Button(L10n.text("update.failure.show_ways"), action: showWays).buttonStyle(.main)
                } else if updater.flow.phase == .idle || updater.flow.phase == .upToDate, let notes = release.notes {
                    Button(L10n.text("main.update.notes")) { NSWorkspace.shared.open(notes) }.buttonStyle(.main)
                }
                UpdateActions(updater: updater, showsCheck: false)
                if !updater.flow.isBusy { closeButton { dismissed = release.version } }
            }
            // A plain card: amber tints stay for problems that need the user.
            .padding(.horizontal, 16).padding(.vertical, 12)
            .mainCardSurface(radius: 14)
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("main.update.later")).accessibilityLabel(L10n.text("main.update.later"))
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

/// When GitHub can't be reached: what failed, a retry, and three other places
/// to get the full installer, which installs over this version.
struct UpdateFailurePanel: View {
    @ObservedObject var updater: AppUpdater
    let failure: UpdateFlow.Failure
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash").font(.system(size: 15, weight: .medium)).foregroundStyle(MainPalette.attention)
                    .frame(width: 20).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let lastSuccess { Text(lastSuccess).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 8)
                retry
            }
            VStack(spacing: 0) {
                UpdateRouteRow(symbol: "arrow.down.circle", title: L10n.text("update.route.github"), detail: githubDetail) {
                    openButton(ProjectSupport.latestRelease)
                }
                Divider()
                UpdateRouteRow(symbol: "globe.asia.australia", title: L10n.text("update.route.mirror"),
                               detail: L10n.text("update.route.mirror_detail")) {
                    openButton(ProjectSupport.downloadMirror)
                }
                Divider()
                UpdateRouteRow(symbol: "person.2", title: L10n.text("update.route.qq", ProjectSupport.qqGroupNumber),
                               detail: L10n.text("update.route.qq_detail")) {
                    QQCopyButton()
                    if let code = ProjectSupport.qqGroupCode() { SupportCodeButton(code: code, expands: false) }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MainPalette.cardBorder))
            Text(L10n.text("update.failure.install_mac")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var title: String {
        switch failure {
        case .check: L10n.text("update.failure.check_title")
        case .download(let release): L10n.text("update.failure.download_title", release.version)
        }
    }
    private var detail: String {
        switch failure {
        case .check: L10n.text("update.failure.check_detail", Self.version ?? "—")
        case .download(let release): L10n.text("update.failure.download_detail", release.version)
        }
    }
    /// Versions before 4.5.0 kept no record of a check that worked, so an
    /// unknown time says nothing rather than claim none ever did.
    private var lastSuccess: String? {
        updater.flow.lastSuccess.map { L10n.text("update.failure.last_success", L10n.date($0)) }
    }
    /// The found version's own file, or the latest one's ending.
    private var githubDetail: String {
        switch failure {
        case .check: L10n.text("update.route.github_latest", "universal.dmg")
        case .download(let release): L10n.text("update.route.github_file", "Codex-Pacer-\(release.version)-universal.dmg")
        }
    }

    @ViewBuilder private var retry: some View {
        if updater.flow.isBusy {
            ProgressView().controlSize(.small).frame(height: 22)
        } else {
            switch failure {
            case .check:
                Button(L10n.text("update.failure.retry_check")) { updater.checkForUpdates() }
                    .buttonStyle(.mainProminent).disabled(updater.enabled && !updater.canCheck)
            case .download:
                Button(L10n.text("update.failure.retry_download")) { updater.installUpdate() }
                    .buttonStyle(.mainProminent).disabled(updater.enabled && !updater.canCheck)
            }
        }
    }

    private func openButton(_ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(L10n.text("update.route.open"))
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
        }
        .help(url.absoluteString)
    }
}

/// One place to get Pacer: what it is, how to use it, and its buttons.
private struct UpdateRouteRow<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).textSelection(.enabled)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions }.buttonStyle(.main).fixedSize()
        }
        .padding(.vertical, 9)
    }
}

/// Copies the QQ group's number, saying so for a moment.
private struct QQCopyButton: View {
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button(L10n.text(copied ? "support.share.copied" : "support.qq.copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProjectSupport.qqGroupNumber, forType: .string)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
    }
}
