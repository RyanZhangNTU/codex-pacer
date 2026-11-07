import PacerCore
import SwiftUI

/// The Collapsed Bar page: the bar itself to click and drag, every component
/// by group to add or remove, and the settings of the one selected. Changes
/// reach the real bar at once; what each component is sits behind ⓘ.
struct SettingsCollapsedBarPane: View {
    @Environment(\.pacerAccent) private var accent
    @ObservedObject var model: IslandModel
    @Binding var layout: CompactIslandLayout
    @Binding var selection: CompactIslandLayout.Component?
    @Binding var singleTask: ActivityBadgeSingleTask
    @Binding var metric: String
    @Binding var windowID: String
    @Binding var claudeWindowID: String
    @Binding var quotaRings: [String]
    let providers: [AgentProvider]
    let deepseekHasBudget: Bool
    let openNotifications: () -> Void
    /// Where the DeepSeek page's ring link lands.
    static let inspectorAnchor = "quotaGauge"

    private var available: [CompactIslandLayout.Component] {
        CompactIslandLayout.Group.allCases.flatMap(\.components).filter { $0.isAvailable(for: Set(providers)) }
    }

    /// The chosen component, or the first one on the bar, so the settings
    /// card always describes something.
    private var selected: CompactIslandLayout.Component? {
        if let selection, available.contains(selection) { return selection }
        let placed = CompactIslandLayout.Lane.allCases.flatMap { layout.visibleComponents(in: $0, providers: Set(providers)) }
        return placed.first ?? available.first
    }

    var body: some View {
        CompactLayoutEditor(model: model, layout: $layout, providers: Set(providers),
                            selection: Binding(get: { selected }, set: { selection = $0 }))
        HStack(alignment: .top, spacing: 14) {
            library.frame(maxWidth: .infinity)
            if let selected {
                ComponentInspector(component: selected, placed: layout.components.contains(selected), options: { options(selected) },
                                   toggle: { toggle(selected) })
                    .frame(width: 264)
                    .id(Self.inspectorAnchor)
            }
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("main.collapsed.components")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(CompactIslandLayout.Group.allCases, id: \.self) { group in
                    let items = group.components.filter { $0.isAvailable(for: Set(providers)) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.label).font(.system(size: 11.5)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        if items.isEmpty {
                            Text(L10n.text("layout.no_quota_providers")).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(items) { tile($0) }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mainCardSurface()
        }
    }

    private func tile(_ component: CompactIslandLayout.Component) -> some View {
        let on = layout.components.contains(component)
        let isSelected = selected == component
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            selection = component
            toggle(component)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: component.symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary).frame(width: 16)
                Text(component.label).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark" : "plus").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? accent : Color.secondary)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(on ? MainPalette.fill : .clear, in: shape)
            .overlay(shape.strokeBorder(isSelected ? accent : MainPalette.cardBorder, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(component.label)
        .accessibilityValue(L10n.text(on ? "main.collapsed.shown" : "main.collapsed.hidden"))
        .accessibilityHint(L10n.text(on ? "main.collapsed.remove" : "main.collapsed.add"))
    }

    private func toggle(_ component: CompactIslandLayout.Component) {
        if layout.components.contains(component) {
            layout.hide(component)
        } else {
            layout.move(component, to: component.preferredLane)
        }
    }

    // MARK: Settings of the selected component

    /// Only what changes the selected component; the quota windows follow
    /// every component that shows a quota.
    @ViewBuilder private func options(_ component: CompactIslandLayout.Component) -> some View {
        switch component {
        case .activity:
            CardPicker(title: L10n.text("layout.single_task"), selection: $singleTask) {
                ForEach(ActivityBadgeSingleTask.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        case .quota:
            CardRow(title: L10n.text("settings.compact_metric")) {
                MainSegmented(options: [("remaining", L10n.text("settings.remaining_quota")), ("pace", L10n.text("settings.pace_percentage"))],
                              selection: $metric, label: L10n.text("settings.compact_metric"))
            }
            windowPickers
        case .quotaGauge:
            ringPickers
            windowPickers
        case .timeRemaining:
            windowPickers
        case .warnings:
            Button(action: openNotifications) {
                HStack(spacing: 6) {
                    Text(L10n.text("main.collapsed.warnings_choose")).font(.system(size: 13)).foregroundStyle(Color.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var windowPickers: some View {
        if providers.contains(.codex) { quotaWindowPicker(.codex, selection: $windowID) }
        if providers.contains(.claude) { quotaWindowPicker(.claude, selection: $claudeWindowID) }
    }

    /// Which of the provider's limits the bar shows, 5 hours or 7 days. An
    /// earlier saved window id shows as its period and is kept until a new
    /// choice. A weekly-only account has nothing to choose, so it shows 7 days.
    @ViewBuilder private func quotaWindowPicker(_ provider: AgentProvider, selection: Binding<String>) -> some View {
        let title = L10n.text("provider.window_selection", provider.displayName)
        if model.providerIsWeeklyOnly(provider) {
            CardRow(title: title) { Text(QuotaWindowSelection.weekly.label).font(.system(size: 12.5)).foregroundStyle(.secondary) }
        } else {
            CardPicker(title: title, info: L10n.text("provider.window_info", provider.displayName), selection: Binding(
                get: { QuotaWindowSelection(saved: selection.wrappedValue, snapshot: model.providerQuota(provider)) },
                set: { selection.wrappedValue = $0.rawValue })) {
                ForEach(QuotaWindowSelection.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }

    /// Which service each ring shows. Unset follows the services in order.
    @ViewBuilder private var ringPickers: some View {
        let automatic: [AgentProvider] = {
            var result = Array(providers.filter { $0 != .deepseek }.prefix(2))
            if result.count == 1, providers.contains(.deepseek) { result.append(.deepseek) }
            return result
        }()
        let current = QuotaRingSlot.allCases.map { slot -> String in
            let saved = quotaRings[slot.rawValue]
            if saved.isEmpty, quotaRings.allSatisfy(\.isEmpty) { return slot.rawValue < automatic.count ? automatic[slot.rawValue].rawValue : "none" }
            return saved.isEmpty ? "none" : saved
        }
        let showsDeepSeek = current.contains(AgentProvider.deepseek.rawValue) && providers.contains(.deepseek)
        ForEach(QuotaRingSlot.allCases, id: \.self) { slot in
            CardPicker(title: L10n.text(slot == .outer ? "layout.ring_outer" : "layout.ring_inner"),
                       info: showsDeepSeek && current[slot.rawValue] == AgentProvider.deepseek.rawValue && deepseekHasBudget
                           ? L10n.text("layout.ring_deepseek") : nil,
                       selection: Binding(get: { current[slot.rawValue] }, set: { value in
                           quotaRings = current; quotaRings[slot.rawValue] = value
                       })) {
                ForEach(providers, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                Text(L10n.text("layout.ring_none")).tag("none")
            }
        }
        if showsDeepSeek, !deepseekHasBudget {
            Text(L10n.text("layout.ring_deepseek_needs_budget")).font(.system(size: 12)).foregroundStyle(MainPalette.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
        if quotaRings.contains(where: { !$0.isEmpty }) {
            CardRow(title: L10n.text("main.collapsed.rings_custom")) {
                Button(L10n.text("layout.ring_automatic")) { quotaRings = QuotaRingSlot.allCases.map { _ in "" } }.buttonStyle(.main)
            }
        }
    }
}

/// The selected component's card: its name with ⓘ, Add or Remove, then the
/// options that change it.
private struct ComponentInspector<Options: View>: View {
    @Environment(\.pacerAccent) private var accent
    let component: CompactIslandLayout.Component
    let placed: Bool
    @ViewBuilder let options: () -> Options
    let toggle: () -> Void
    @State private var showsInfo = false

    var body: some View {
        MainCard(title: L10n.text("main.collapsed.selected")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: component.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(component.label).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    InfoButton(title: component.label, isOn: $showsInfo)
                    Spacer(minLength: 4)
                    if placed {
                        Button(L10n.text("main.collapsed.remove"), action: toggle).buttonStyle(.main)
                    } else {
                        Button(L10n.text("main.collapsed.add"), action: toggle).buttonStyle(.mainProminent)
                    }
                }
                if showsInfo { InfoBox(text: component.detail) }
            }
            if placed { options() }
        }
        .onChange(of: component) { _, _ in showsInfo = false }
    }
}
