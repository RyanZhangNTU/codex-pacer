import SwiftUI
import PacerCore

struct CompactLayoutEditor: View {
    @ObservedObject var model: IslandModel
    let attached: Bool
    let saving: Bool
    let validation: String?
    let onSave: (CompactIslandLayout) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CompactIslandLayout
    @State private var previewWidth: CGFloat = 320
    @State private var dragged: CompactIslandLayout.Component?
    @State private var dragLocation = CGPoint.zero
    @State private var dropRegions: [CompactEditorDropRegion] = []
    @FocusState private var focusedComponent: CompactIslandLayout.Component?
    private let accent = Color(red: 0.56, green: 0.84, blue: 0.79)

    init(model: IslandModel, layout: CompactIslandLayout, attached: Bool,
         saving: Bool, validation: String?, onSave: @escaping (CompactIslandLayout) -> Void) {
        self.model = model; self.attached = attached; self.saving = saving
        self.validation = validation; self.onSave = onSave
        _draft = State(initialValue: layout.normalized)
    }
    private var camera: CGFloat { attached ? model.notchWidth : 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("layout.title")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(L10n.text("common.restore_defaults")) { draft = .standard }
                    .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(L10n.text("layout.help")).font(.system(size: 12)).foregroundStyle(.secondary)
            preview
            HStack(alignment: .top, spacing: 16) {
                laneEditor(.leading)
                laneEditor(.trailing)
            }.frame(height: 84)
            Divider().padding(.vertical, 2)
            HStack(alignment: .top, spacing: 16) {
                ForEach(CompactIslandLayout.Group.allCases, id: \.rawValue) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label).font(.system(size: 13, weight: .semibold)).padding(.leading, 6)
                        VStack(spacing: 3) {
                            ForEach(group.components) { component in componentChoice(component) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
            if let validation {
                Text(validation).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L10n.text("layout.single_save")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(saving ? "common.saving" : "common.save")) { onSave(draft.normalized) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 820, height: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(saving)
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
    private var preview: some View {
        GeometryReader { geometry in
            let scale = min(1, (geometry.size.width - 32) / max(80, previewWidth))
            CompactIslandHeader(model: model, layout: draft, baseHeight: 38, notchWidth: camera, measuresLayout: false)
                .frame(width: max(80, previewWidth), height: 38)
                .foregroundStyle(.white)
                .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 18,
                    bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: attached ? 0 : 18))
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false).accessibilityHidden(true)
                .onPreferenceChange(CompactHeaderIdealWidth.self) { previewWidth = max(camera > 0 ? camera + 60 : 80, $0 + 2) }
        }
        .frame(height: 74)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(L10n.text("layout.preview"))
    }
    private func laneEditor(_ lane: CompactIslandLayout.Lane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(draft[lane]) { component in chip(component) }
                    if draft[lane].isEmpty {
                        Text(L10n.text("layout.drop_here")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(.vertical, 7)
                    }
                }.padding(.bottom, 3)
            }.scrollIndicators(.hidden)
        }
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
                .onKeyPress(.leftArrow) { draft.shift(component, by: -1); return .handled }
                .onKeyPress(.rightArrow) { draft.shift(component, by: 1); return .handled }
                .accessibilityLabel(component.label)
                .accessibilityAction(named: Text(L10n.text("layout.move_left"))) { draft.move(component, to: .leading) }
                .accessibilityAction(named: Text(L10n.text("layout.move_right"))) { draft.move(component, to: .trailing) }
            Button { draft.hide(component) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 15, height: 20).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("layout.hide_component", component.label))
                .accessibilityLabel(L10n.text("layout.hide_component", component.label))
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(focusedComponent == component ? accent : Color.primary.opacity(0.08), lineWidth: 1))
        .background(dropRegion(draft.leading.contains(component) ? .leading : .trailing, before: component))
        .contextMenu {
            Button(L10n.text("layout.move_left")) { draft.move(component, to: .leading) }
            Button(L10n.text("layout.move_right")) { draft.move(component, to: .trailing) }
            Button(L10n.text("layout.earlier")) { draft.shift(component, by: -1) }
            Button(L10n.text("layout.later")) { draft.shift(component, by: 1) }
        }
    }
    private func componentChoice(_ component: CompactIslandLayout.Component) -> some View {
        let shown = draft.components.contains(component)
        return Button {
            if shown { draft.hide(component) }
            else { draft.move(component, to: component.preferredLane) }
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
                draft.move(component, to: lane, before: before)
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
