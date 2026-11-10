import AppKit
import PacerCore
import SwiftUI

/// The once-per-update note, drawn like the main window: the app icon and a
/// large title, each highlight with its symbol, its explanation behind ⓘ and
/// the setting it introduces offered in place, then one wide Continue.
/// Release Notes has the full list.
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
    /// Opens the main window on the page a highlight introduces.
    var onOpenPane: (SettingsPane) -> Void = { _ in }
    /// The height the note needs, reported as explanations open and close
    /// so its window can grow to fit them.
    var onNaturalHeight: (CGFloat) -> Void = { _ in }
    let onDone: () -> Void
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showsEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showsEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true

    var body: some View {
        VStack(spacing: 0) {
            if height != nil {
                ScrollView(.vertical) { content.background(Self.naturalHeight) }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
            } else {
                content
            }
            footer.background(Self.naturalHeight)
        }
        .frame(width: Self.width, height: height)
        .fixedSize(horizontal: false, vertical: true)
        .background(MainPalette.page)
        .environment(\.locale, L10n.locale)
        .modifier(SavedPacerAccent())
        .onPreferenceChange(WhatsNewNaturalHeight.self) { natural in
            guard natural > 0 else { return }
            DispatchQueue.main.async { onNaturalHeight(natural) }
        }
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
                    VStack(alignment: .leading, spacing: 14) {
                        // Skipped updates keep their own headings, newest first.
                        if releases.count > 1 {
                            Text(L10n.text("whats_new.version", release.version)).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                            WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin, large: true, detailInInfo: true,
                                            openPane: onOpenPane)
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

    private static var naturalHeight: some View {
        GeometryReader { Color.clear.preference(key: WhatsNewNaturalHeight.self, value: $0.size.height) }
    }
}

/// The scrolled content and the footer together.
private struct WhatsNewNaturalHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// One highlight, shared by the update note and the Help & Updates page,
/// with the setting it introduces offered in place: a switch, or the way to
/// the page that holds it.
struct WhatsNewItemRow: View {
    let item: WhatsNew.Item
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    /// The update note draws each highlight larger, as a feature list.
    var large = false
    /// Keeps the explanation behind ⓘ; a sign-in item problem still shows in
    /// place.
    var detailInInfo = false
    /// Opens the main window on a page; nil leaves page links out.
    var openPane: ((SettingsPane) -> Void)? = nil
    @State private var showsInfo = false
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showsEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showsEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true

    var body: some View {
        let login = item.control == .openAtLogin
        let warning = login ? launchAtLogin.failure ?? (launchAtLogin.needsApproval ? L10n.text("settings.login_item_approval") : nil) : nil
        let title = L10n.text(item.titleKey)
        let symbolSize: CGFloat = large ? 40 : 28
        let spacing: CGFloat = large ? 14 : 12
        let showsDetail = !detailInInfo || warning != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: large && showsDetail ? .top : .center, spacing: spacing) {
                FeatureSymbol(symbol: item.symbol, size: symbolSize)
                VStack(alignment: .leading, spacing: large ? 3 : 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: large ? 13.5 : 13, weight: large ? .semibold : .regular))
                        if detailInInfo { InfoButton(title: title, isOn: $showsInfo) }
                    }
                    if showsDetail {
                        Text(warning ?? L10n.text(item.detailKey)).font(.system(size: large ? 12.5 : 11.5)).lineSpacing(large ? 1.5 : 0)
                            .foregroundStyle(warning == nil ? Color.secondary : MainPalette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, large && showsDetail ? 1 : 0)
                Spacer(minLength: 8)
                control.padding(.top, large && showsDetail ? 9 : 0)
            }
            if detailInInfo, showsInfo {
                InfoBox(text: L10n.text(item.detailKey)).padding(.leading, symbolSize + spacing)
            }
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
        case .openExpandedPanel, .openCollapsedBar, .openAppearance:
            item.control?.settingsPane.map(pageLink)
        case nil:
            EmptyView()
        }
    }

    /// "Settings ›" to the page that holds what this highlight introduces.
    @ViewBuilder private func pageLink(_ pane: SettingsPane) -> some View {
        if let openPane {
            Button { openPane(pane) } label: {
                HStack(spacing: 3) {
                    Text(L10n.text("whats_new.open_settings")).font(.system(size: 12.5))
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                }
                // Link blue, like Release Notes beside it on Help & Updates.
                .foregroundStyle(Color(nsColor: .linkColor)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(L10n.text("whats_new.open_settings_label", L10n.text(item.titleKey)))
        }
    }
}

extension WhatsNew.Item.Control {
    /// The main window page a highlight's link opens; nil for a switch.
    var settingsPane: SettingsPane? {
        switch self {
        case .openExpandedPanel: .expandedPanel
        case .openCollapsedBar: .collapsedBar
        case .openAppearance: .appearance
        case .openAtLogin, .showEmbeddedSessions, .showAppButtons: nil
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
