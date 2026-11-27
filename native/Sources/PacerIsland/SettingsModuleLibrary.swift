import PacerCore
import SwiftUI

private struct ModuleTile: View {
    let entry: ModuleLibrary.Entry
    let open: () -> Void
    let toggle: () -> Void
    @State private var showsInfo = false

    var body: some View {
        let name = entry.provider.settingsTitle
        let state = L10n.text(entry.state.labelKey)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            // The body button sits behind the three independent controls.
            Button(action: open) {
                shape.fill(LibraryPalette.freeFill).contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(state)
            .accessibilitySortPriority(1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    ProviderAppIcon(provider: entry.provider, size: 28)
                        .opacity(entry.detected || entry.enabled ? 1 : 0.55)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Text(name).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    InfoButton(title: name, isOn: $showsInfo)
                        .padding(.leading, 3)
                    Spacer(minLength: 4)
                    Text(state).font(.system(size: 11.5))
                        .foregroundStyle(entry.enabled ? MainPalette.positive : Color.secondary)
                        .fixedSize().allowsHitTesting(false).accessibilityHidden(true)
                    LibraryRoundButton(placed: entry.enabled, addLabel: L10n.text("modules.turn_on", name),
                                       removeLabel: L10n.text("modules.turn_off", name), toggle: toggle)
                        .frame(height: 32)
                }
                // The summary and, for an app that isn't installed, a quiet way to
                // get it live behind the ⓘ; the tile itself stays one line.
                if showsInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text(entry.summaryKey))
                            .fixedSize(horizontal: false, vertical: true)
                            .allowsHitTesting(false)
                        if !entry.detected, let site = entry.website {
                            Link(destination: site) {
                                HStack(spacing: 2) {
                                    Text(L10n.text("modules.get", name))
                                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("modules.get", name))
                        }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.leading, 38).padding(.trailing, 10)
                }
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(shape.strokeBorder(LibraryPalette.border).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
    }
}

private struct MoreComingTile: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").frame(width: 28).accessibilityHidden(true)
            Text(L10n.text("modules.more_coming")).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(LibraryPalette.buttonRing, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct SettingsModuleLibraryPane: View {
    let library: ModuleLibrary
    let open: (AgentProvider) -> Void
    let toggle: (AgentProvider) -> Void

    var body: some View {
        let missing = library.notFound
        section("modules.on_this_computer", entries: library.found, isLast: missing.isEmpty)
        if !missing.isEmpty {
            section("modules.not_found", entries: missing, isLast: true)
        }
    }

    private func section(_ titleKey: String, entries: [ModuleLibrary.Entry], isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(titleKey)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text(L10n.text("modules.empty")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if !entries.isEmpty || isLast {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        ModuleTile(entry: entry, open: { open(entry.provider) }, toggle: { toggle(entry.provider) })
                    }
                    if isLast { MoreComingTile() }
                }
            }
        }
    }
}
