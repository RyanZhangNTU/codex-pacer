import AppKit
import PacerCore
import SwiftUI

/// The once-per-update note: each new version's highlights, with the setting a
/// highlight introduces offered in place. Release Notes has the full list.
struct WhatsNewView: View {
    static let width: CGFloat = 460
    private static let repository = "https://github.com/RyanZhangNTU/codex-pacer"

    let version: String
    let releases: [WhatsNew.Release]
    /// Nil only while measuring the natural height before the window opens.
    var height: CGFloat? = nil
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    /// Applies a preference changed here to the running island.
    var onSettingsChange: () -> Void = {}
    let onDone: () -> Void
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showsEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showsEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("whats_new.title")).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("whats_new.version", version)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            .fixedSize(horizontal: false, vertical: true)
            if height != nil {
                ScrollView(.vertical) { highlights }
                    .frame(maxHeight: .infinity)
            } else {
                highlights
            }
            Divider()
            HStack(spacing: 10) {
                Button(L10n.text("whats_new.release_notes")) {
                    if let url = URL(string: Self.repository + "/releases/tag/v" + version) { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 8)
                Button(L10n.text("whats_new.done"), action: onDone)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width, height: height)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, L10n.locale)
        .onChange(of: [showsEmbeddedClaudeSessions, showsEmbeddedCodexSessions]) { _, _ in onSettingsChange() }
        .onChange(of: showsAppButtons) { _, _ in onSettingsChange() }
    }

    private var highlights: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(releases, id: \.version) { release in
                // Skipped updates keep their own headings, newest first.
                if releases.count > 1 {
                    Text(L10n.text("whats_new.version", release.version)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.leading, 10).padding(.top, release == releases.first ? 0 : 8)
                }
                VStack(spacing: 0) {
                    ForEach(Array(release.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.leading, 50) }
                        WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
                .welcomeGroup()
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 18)
    }
}

/// One highlight, shared by the update note and Settings, with the setting it
/// introduces offered in place.
struct WhatsNewItemRow: View {
    let item: WhatsNew.Item
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showsEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showsEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true

    var body: some View {
        let login = item.control == .openAtLogin
        let warning = login ? launchAtLogin.failure ?? (launchAtLogin.needsApproval ? L10n.text("settings.login_item_approval") : nil) : nil
        HStack(spacing: 12) {
            SettingsIconTile(symbol: item.symbol, tint: .accentColor, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(item.titleKey))
                Text(warning ?? L10n.text(item.detailKey)).font(.system(size: 11))
                    .foregroundStyle(warning == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch item.control {
            case .openAtLogin:
                Toggle(L10n.text(item.titleKey), isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            case .showEmbeddedSessions:
                Toggle(L10n.text(item.titleKey), isOn: Binding(get: { showsEmbeddedClaudeSessions && showsEmbeddedCodexSessions },
                    set: { showsEmbeddedClaudeSessions = $0; showsEmbeddedCodexSessions = $0 })).labelsHidden().toggleStyle(.switch)
            case .showAppButtons:
                Toggle(L10n.text(item.titleKey), isOn: $showsAppButtons).labelsHidden().toggleStyle(.switch)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 13))
    }
}
