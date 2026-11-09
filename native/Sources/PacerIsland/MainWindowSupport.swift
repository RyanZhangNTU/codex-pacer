import AppKit
import PacerCore
import SwiftUI

/// Pages of Pacer's main window, which grew out of the Settings window. The
/// sidebar groups them as data (Overview, History), services, preferences and
/// a footer with About and Support. Earlier stored pages open where their
/// content moved.
enum SettingsPane: String, CaseIterable, Identifiable {
    case overview, history, codex, claude, deepseek, remote, appearance, collapsedBar, notifications, general, about, support
    static let defaultsKey = "settingsPane"
    /// The sidebar's groups, in order; About and Support sit in its footer.
    static let groups: [[SettingsPane]] = [[.overview, .history], [.codex, .claude, .deepseek, .remote],
                                           [.appearance, .collapsedBar, .notifications, .general]]
    var id: String { rawValue }

    init?(stored value: String) {
        switch value {
        case "connections": self = .remote
        case "reminders": self = .notifications
        case "whatsNew", "help": self = .about
        default: self.init(rawValue: value)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(stored:)) ?? .overview
    }

    init(provider: AgentProvider) {
        switch provider {
        case .codex: self = .codex
        case .claude: self = .claude
        case .deepseek: self = .deepseek
        }
    }

    var provider: AgentProvider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .deepseek: .deepseek
        default: nil
        }
    }

    var title: String {
        switch self {
        case .overview: L10n.text("main.pane.overview")
        case .history: L10n.text("main.pane.history")
        case .codex: AgentProvider.codex.displayName
        case .claude: AgentProvider.claude.displayName
        case .deepseek: AgentProvider.deepseek.displayName
        case .remote: L10n.text("main.pane.remote")
        case .appearance: L10n.text("settings.pane.appearance")
        case .collapsedBar: L10n.text("settings.pane.collapsed")
        case .notifications: L10n.text("main.pane.notifications")
        case .general: L10n.text("settings.pane.general")
        case .about: L10n.text("main.pane.about")
        case .support: L10n.text("main.pane.support")
        }
    }

    /// Monochrome symbols; services draw their own colored tile instead.
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "chart.xyaxis.line"
        case .codex: AgentProvider.codex.glyph
        case .claude: AgentProvider.claude.glyph
        case .deepseek: AgentProvider.deepseek.glyph
        case .remote: "server.rack"
        case .appearance: "circle.lefthalf.filled"
        case .collapsedBar: "rectangle.topthird.inset.filled"
        case .notifications: "bell"
        case .general: "gearshape"
        case .about: "info.circle"
        case .support: "heart"
        }
    }

    /// Words beyond the title that find this page from the sidebar search.
    var searchTerms: String { L10n.text("main.search." + rawValue) }

    /// The welcome guide links to pages with System Settings style tiles.
    var tileSymbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .notifications: "bell.badge.fill"
        case .support: "heart.fill"
        default: symbol
        }
    }

    var tint: Color {
        switch self {
        case .codex, .claude, .deepseek: provider?.brand ?? .gray
        case .appearance: Color(red: 0.44, green: 0.4, blue: 0.96)
        case .collapsedBar: Color(red: 0.2, green: 0.22, blue: 0.27)
        case .notifications: Color(red: 1, green: 0.3, blue: 0.29)
        case .remote: Color(red: 0.16, green: 0.5, blue: 1)
        case .support: Color(red: 0.96, green: 0.36, blue: 0.42)
        case .overview, .history, .general, .about: Color(white: 0.52)
        }
    }

    var glyphColor: Color { provider == nil ? .white : Color.black.opacity(0.72) }
}

/// About shows either the update notes or the help legend.
enum AboutTab: String, CaseIterable, Identifiable {
    case whatsNew, help
    static let defaultsKey = "settingsAboutTab"
    var id: String { rawValue }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let tab = defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) { return tab }
        return defaults.string(forKey: SettingsPane.defaultsKey) == "help" ? .help : .whatsNew
    }

    var title: String { self == .whatsNew ? L10n.text("whats_new.window_title") : L10n.text("settings.pane.help") }
}

/// Whether Pacer has a Dock icon: while its window is open (the default),
/// always, or never. The island itself never needs one.
enum DockIconPreference: String, CaseIterable, Identifiable {
    case whileOpen, always, never
    static let defaultsKey = "dockIcon"
    var id: String { rawValue }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .whileOpen
    }

    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    func showsIcon(windowOpen: Bool) -> Bool { self == .always || (self == .whileOpen && windowOpen) }

    var label: String { L10n.text("main.dock." + rawValue) }
}

/// The native sidebar material, behind the window like System Settings.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Search, then the grouped pages, then Help & Updates and Support & Feedback. Selection is
/// a neutral fill: color in the sidebar only says which service a row is, and
/// amber only that something needs the user.
struct MainWindowSidebar: View {
    @Environment(\.pacerAccent) private var accent
    @Binding var selection: SettingsPane
    let isDisabled: (SettingsPane) -> Bool
    let needsAttention: (SettingsPane) -> Bool
    /// A found version replaces the installed one under Help & Updates.
    var updateVersion: String?
    @State private var query = ""
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let width: CGFloat = 220

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [SettingsPane] {
        let needle = trimmedQuery.lowercased()
        return SettingsPane.allCases.filter { ($0.title + " " + $0.searchTerms).lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField.padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if trimmedQuery.isEmpty {
                        ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { index, group in
                            if let title = groupTitle(index) {
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group) { row($0) }
                        }
                    } else if matches.isEmpty {
                        Text(L10n.text("main.search_empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    } else {
                        ForEach(matches) { row($0) }
                    }
                }
            }
            .scrollIndicators(.never)
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func groupTitle(_ index: Int) -> String? {
        switch index {
        case 1: L10n.text("main.group.services")
        case 2: L10n.text("main.group.preferences")
        default: nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("main.search"), text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { if !trimmedQuery.isEmpty, let first = matches.first { choose(first) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("main.search_clear"))
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func choose(_ pane: SettingsPane) {
        selection = pane
        query = ""
    }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = selection == pane
        return Button { choose(pane) } label: {
            HStack(spacing: 9) {
                icon(pane)
                Text(pane.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if isDisabled(pane) {
                    Text(L10n.text("settings.module_off")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if needsAttention(pane) {
                    Circle().fill(PacerPalette.attention).frame(width: 7, height: 7)
                        .accessibilityLabel(L10n.text("main.needs_attention"))
                }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func icon(_ pane: SettingsPane) -> some View {
        if let provider = pane.provider {
            SettingsIconTile(symbol: provider.glyph, tint: provider.shade(light: false), glyph: Color.black.opacity(0.72))
        } else {
            Image(systemName: pane.symbol).font(.system(size: 13))
                .foregroundStyle(pane == .support ? Color(red: 0.96, green: 0.36, blue: 0.42) : Color.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            let aboutSelected = selection == .about
            Button { choose(.about) } label: {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                        .frame(width: 22, height: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(SettingsPane.about.title).font(.system(size: 13))
                        if let updateVersion {
                            Text(L10n.text("main.update.sidebar", updateVersion)).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accent).monospacedDigit()
                        } else {
                            Text(Self.version ?? L10n.text("build.development")).font(.system(size: 11))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 4)
                    if updateVersion != nil {
                        Circle().fill(accent).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(aboutSelected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(aboutSelected ? .isSelected : [])
            row(.support)
        }
    }
}
