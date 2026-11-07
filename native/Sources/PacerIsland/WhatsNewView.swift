import AppKit
import PacerCore
import SwiftUI

/// The once-per-update note, drawn like the main window: the app icon and a
/// large title, each highlight with its symbol and the setting it introduces
/// offered in place, then one wide Continue. Release Notes has the full list.
struct WhatsNewView: View {
    static let width: CGFloat = 480
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
            if height != nil {
                ScrollView(.vertical) { content }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
            } else {
                content
            }
            footer
        }
        .frame(width: Self.width, height: height)
        .fixedSize(horizontal: false, vertical: true)
        .background(MainPalette.page)
        .environment(\.locale, L10n.locale)
        .modifier(SavedPacerAccent())
        .onChange(of: [showsEmbeddedClaudeSessions, showsEmbeddedCodexSessions]) { _, _ in onSettingsChange() }
        .onChange(of: showsAppButtons) { _, _ in onSettingsChange() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 72, height: 72).accessibilityHidden(true)
            Text(L10n.text("main.whats_new.title", version)).font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(releases, id: \.version) { release in
                    VStack(alignment: .leading, spacing: 16) {
                        // Skipped updates keep their own headings, newest first.
                        if releases.count > 1 {
                            Text(L10n.text("whats_new.version", release.version)).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                            WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin, large: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: onDone) { Text(L10n.text("whats_new.done")).frame(maxWidth: .infinity) }
                .buttonStyle(MainButtonStyle(prominent: true, height: 34))
                .keyboardShortcut(.defaultAction)
            Button {
                if let url = URL(string: Self.repository + "/releases/tag/v" + version) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 3) {
                    Text(L10n.text("whats_new.release_notes"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold)).accessibilityHidden(true)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40).padding(.top, 6).padding(.bottom, 22)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One highlight, shared by the update note and the Help & Updates page,
/// with the setting it introduces offered in place.
struct WhatsNewItemRow: View {
    let item: WhatsNew.Item
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    /// The update note draws each highlight larger, as a feature list.
    var large = false
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showsEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showsEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true

    var body: some View {
        let login = item.control == .openAtLogin
        let warning = login ? launchAtLogin.failure ?? (launchAtLogin.needsApproval ? L10n.text("settings.login_item_approval") : nil) : nil
        HStack(alignment: large ? .top : .center, spacing: large ? 14 : 12) {
            FeatureSymbol(symbol: item.symbol, size: large ? 40 : 28)
            VStack(alignment: .leading, spacing: large ? 3 : 2) {
                Text(L10n.text(item.titleKey)).font(.system(size: large ? 13.5 : 13, weight: large ? .semibold : .regular))
                Text(warning ?? L10n.text(item.detailKey)).font(.system(size: large ? 12.5 : 11.5)).lineSpacing(large ? 1.5 : 0)
                    .foregroundStyle(warning == nil ? Color.secondary : MainPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, large ? 1 : 0)
            Spacer(minLength: 8)
            control.padding(.top, large ? 9 : 0)
        }
    }

    @ViewBuilder private var control: some View {
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
}

/// A highlight's symbol in the accent color on a soft tile of the same hue.
struct FeatureSymbol: View {
    let symbol: String
    var size: CGFloat = 40
    /// Nil draws in the window's accent.
    var tint: Color? = nil
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        let tint = tint ?? accent
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}
