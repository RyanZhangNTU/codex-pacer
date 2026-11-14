import AppKit
import PacerCore
import SwiftUI

/// What one module tile shows. The module library page and the welcome
/// guide build these from Core's module library.
struct ModuleTileContent: Identifiable, Equatable {
    let provider: AgentProvider
    let on: Bool
    let detected: Bool
    /// The service's site, offered when it is not on this computer.
    let getURL: URL?
    var id: String { provider.rawValue }
    var name: String { provider.displayName }
    var summary: String { L10n.text("module." + provider.rawValue + ".summary") }
    var state: String { L10n.text(on ? "modules.state.on" : detected ? "modules.state.off" : "modules.state.not_found") }
}

/// A module in the library, drawn like the bar's component tiles: clicking
/// it opens the service's page, the round button turns it on or off. A
/// service not found here can still be turned on, for data in a custom
/// folder, and links to where to get it.
struct ModuleTile: View {
    @Environment(\.pacerAccent) private var accent
    let content: ModuleTileContent
    let open: () -> Void
    let toggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .center, spacing: 0) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 11) {
                    ProviderAppIcon(provider: content.provider, size: 28)
                        .opacity(content.detected || content.on ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(content.name).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(content.on ? LibraryPalette.placedInk : LibraryPalette.freeInk)
                            Text(content.state).font(.system(size: 11))
                                .foregroundStyle(content.on ? accent : LibraryPalette.freeIcon)
                        }
                        Text(content.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12).padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(content.name + ", " + content.state)
            .accessibilityHint(content.summary)
            LibraryRoundButton(placed: content.on, addLabel: L10n.text("modules.turn_on", content.name),
                               removeLabel: L10n.text("modules.turn_off", content.name), toggle: toggle)
        }
        // The site link sits under the summary, outside the tile's own button.
        .overlay(alignment: .bottomLeading) {
            if let url = content.getURL, !content.detected {
                Link(L10n.text("modules.get", content.name), destination: url)
                    .font(.system(size: 11.5)).padding(.leading, 51).padding(.bottom, 9)
            }
        }
        .padding(.bottom, content.getURL != nil && !content.detected ? 18 : 0)
        .background(content.on ? LibraryPalette.placedFill : LibraryPalette.freeFill, in: shape)
        .overlay(shape.strokeBorder(LibraryPalette.border, lineWidth: 1))
    }
}

/// Tiles two to a row where the page is wide enough.
struct ModuleTileGrid: View {
    let tiles: [ModuleTileContent]
    let open: (AgentProvider) -> Void
    let toggle: (AgentProvider) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(tiles) { tile in
                ModuleTile(content: tile, open: { open(tile.provider) }, toggle: { toggle(tile.provider) })
            }
        }
    }
}

/// The module library: services on this computer first, the rest folded
/// away until asked for. A service turned on here joins the sidebar.
struct SettingsModuleLibraryPane: View {
    let library: ModuleLibrary
    let open: (AgentProvider) -> Void
    let toggle: (AgentProvider) -> Void
    @State private var showsNotFound = false

    var body: some View {
        Text(L10n.text("modules.info")).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        MainCard(title: L10n.text("modules.on_this_computer")) {
            if library.prominent.isEmpty {
                CardRow(title: L10n.text("modules.empty"))
            } else {
                ModuleTileGrid(tiles: library.prominent.map(ModuleTileContent.init(entry:)), open: open, toggle: toggle)
                    .padding(.vertical, 12)
            }
        }
        if !library.collapsed.isEmpty {
            MainCard(title: L10n.text("modules.not_found")) {
                CardRow(title: L10n.text(showsNotFound ? "modules.hide_not_found" : "modules.show_not_found", library.collapsed.count)) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsNotFound.toggle() }
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(showsNotFound ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(showsNotFound ? "modules.hide_not_found" : "modules.show_not_found", library.collapsed.count))
                }
                if showsNotFound {
                    ModuleTileGrid(tiles: library.collapsed.map(ModuleTileContent.init(entry:)), open: open, toggle: toggle)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}

extension ModuleTileContent {
    init(entry: ModuleLibrary.Entry) {
        self.init(provider: entry.provider, on: entry.enabled, detected: entry.detected, getURL: entry.website)
    }
}
