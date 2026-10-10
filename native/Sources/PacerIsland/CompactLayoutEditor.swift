import SwiftUI
import PacerCore

struct CompactLayoutEditor: View {
    @ObservedObject var model: IslandModel
    @Binding var layout: CompactIslandLayout
    @Binding var widthSettings: IslandWidthSettings
    let attached: Bool
    let quotaPreview: CompactQuotaPreview
    @State private var dragged: CompactIslandLayout.Component?
    @State private var dragLocation = CGPoint.zero
    @State private var dropRegions: [CompactEditorDropRegion] = []
    @FocusState private var focusedComponent: CompactIslandLayout.Component?
    private let accent = Color.accentColor
    private var providers: Set<AgentProvider> { Set(quotaPreview.providers) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("layout.preview")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.restore_defaults")) { layout = .standard }
                    .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            IslandWidthControl(model: model, settings: $widthSettings, layout: layout,
                attached: attached, quotaPreview: quotaPreview)
            Picker(L10n.text("settings.width_mode"), selection: $widthSettings.mode) {
                Text(L10n.text("settings.width_adaptive")).tag(IslandWidthSettings.Mode.adaptive)
                Text(L10n.text("settings.width_fixed")).tag(IslandWidthSettings.Mode.fixed)
            }
            .pickerStyle(.segmented)
            Text(L10n.text(widthSettings.mode == .adaptive ? "settings.width_adaptive_help" : "settings.width_fixed_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("layout.help")).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                laneEditor(.leading)
                laneEditor(.trailing)
            }
            Divider().padding(.vertical, 2)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 16) {
                ForEach(CompactIslandLayout.Group.allCases, id: \.rawValue) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label).font(.system(size: 13, weight: .semibold)).padding(.leading, 6)
                        if group == .warnings {
                            Text(L10n.text("layout.warnings_hint")).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(.leading, 6)
                        }
                        VStack(spacing: 3) {
                            ForEach(group.components.filter { $0.isAvailable(for: providers) }) { component in componentChoice(component) }
                            if group == .quota, providers.isEmpty {
                                Text(L10n.text("layout.no_quota_providers")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 6)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Text(L10n.text("layout.providers_hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("layout.single_save")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "compact-editor")
        .onPreferenceChange(CompactEditorDropRegions.self) { dropRegions = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged {
                Text(dragged.label).font(.system(size: 11, weight: .medium)).padding(8)
                    .background(accent, in: Capsule()).foregroundStyle(.black)
                    .position(dragLocation).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.locale, L10n.locale)
    }
    private func laneEditor(_ lane: CompactIslandLayout.Lane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(layout.visibleComponents(in: lane, providers: providers)) { component in chip(component).id(component) }
                        if layout.visibleComponents(in: lane, providers: providers).isEmpty {
                            Text(L10n.text("layout.drop_here")).font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.vertical, 7)
                        }
                    }.padding(.bottom, 3)
                }
                .onChange(of: layout.visibleComponents(in: lane, providers: providers)) { previous, current in
                    if let added = current.first(where: { !previous.contains($0) }) { proxy.scrollTo(added, anchor: .trailing) }
                }
            }
        }
        .frame(height: 56, alignment: .topLeading)
        .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(dragged == nil ? 0 : 0.55), lineWidth: 1))
        .contentShape(Rectangle()).background(dropRegion(lane, before: nil))
        .accessibilityElement(children: .contain).accessibilityLabel(lane.label)
    }
    private func chip(_ component: CompactIslandLayout.Component) -> some View {
        HStack(spacing: 5) {
            Text(component.shortLabel).font(.system(size: 11, weight: .medium)).fixedSize()
                .contentShape(Rectangle()).gesture(rearrangeGesture(component))
                .focusable().focusEffectDisabled().focused($focusedComponent, equals: component)
                .onKeyPress(.leftArrow) { layout.shift(component, by: -1, providers: providers); return .handled }
                .onKeyPress(.rightArrow) { layout.shift(component, by: 1, providers: providers); return .handled }
                .accessibilityLabel(component.label)
                .accessibilityAction(named: Text(L10n.text("layout.move_left"))) { layout.move(component, to: .leading) }
                .accessibilityAction(named: Text(L10n.text("layout.move_right"))) { layout.move(component, to: .trailing) }
            Button { layout.hide(component) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 15, height: 20).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("layout.hide_component", component.label))
                .accessibilityLabel(L10n.text("layout.hide_component", component.label))
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(focusedComponent == component ? accent : Color.primary.opacity(0.08), lineWidth: 1))
        .background(dropRegion(layout.leading.contains(component) ? .leading : .trailing, before: component))
        .contextMenu {
            Button(L10n.text("layout.move_left")) { layout.move(component, to: .leading) }
            Button(L10n.text("layout.move_right")) { layout.move(component, to: .trailing) }
            Button(L10n.text("layout.earlier")) { layout.shift(component, by: -1, providers: providers) }
            Button(L10n.text("layout.later")) { layout.shift(component, by: 1, providers: providers) }
        }
    }
    private func componentChoice(_ component: CompactIslandLayout.Component) -> some View {
        let shown = layout.components.contains(component)
        return Button {
            if shown { layout.hide(component) }
            else { layout.move(component, to: component.preferredLane) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: component.symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(shown ? Color.primary : Color.secondary)
                Text(component.label).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(shown ? Color.primary : Color.secondary)
                Spacer(minLength: 2)
                Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(shown ? accent : Color.secondary.opacity(0.35))
            }.padding(.horizontal, 6).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(component.label)
        .accessibilityLabel(component.label)
        .accessibilityValue(L10n.text(shown ? "layout.shown" : "layout.hidden"))
    }
    private func dropRegion(_ lane: CompactIslandLayout.Lane, before: CompactIslandLayout.Component?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CompactEditorDropRegions.self,
                value: [.init(lane: lane, before: before, frame: geometry.frame(in: .named("compact-editor")))])
        }
    }
    private func rearrangeGesture(_ component: CompactIslandLayout.Component) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("compact-editor"))
            .onChanged { value in dragged = component; dragLocation = value.location }
            .onEnded { value in
                defer { dragged = nil }
                guard let lane = dropRegions.first(where: { $0.before == nil && $0.frame.contains(value.location) })?.lane else { return }
                let before = dropRegions.filter { $0.lane == lane && $0.before != nil }
                    .sorted { $0.frame.midX < $1.frame.midX }
                    .first { value.location.x < $0.frame.midX }?.before
                layout.move(component, to: lane, before: before)
            }
    }
}
private struct CompactEditorDropRegion: Equatable {
    let lane: CompactIslandLayout.Lane
    let before: CompactIslandLayout.Component?
    let frame: CGRect
}
private struct CompactEditorDropRegions: PreferenceKey {
    static var defaultValue: [CompactEditorDropRegion] = []
    static func reduce(value: inout [CompactEditorDropRegion], nextValue: () -> [CompactEditorDropRegion]) { value += nextValue() }
}
