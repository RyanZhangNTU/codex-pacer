import SwiftUI
import PacerCore

struct CompactLayoutEditor: View {
    @ObservedObject var model: IslandModel
    @Binding var layout: CompactIslandLayout
    let attached: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CompactIslandLayout
    @State private var selected: CompactIslandLayout.Component?
    @State private var previewWidth: CGFloat = 320
    @State private var dragged: CompactIslandLayout.Component?
    @State private var dragLocation = CGPoint.zero
    @State private var dropRegions: [CompactEditorDropRegion] = []

    init(model: IslandModel, layout: Binding<CompactIslandLayout>, attached: Bool) {
        self.model = model; _layout = layout; self.attached = attached
        _draft = State(initialValue: layout.wrappedValue)
    }
    private var camera: CGFloat { attached ? model.notchWidth : 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("layout.title")).font(.system(size: 21, weight: .semibold))
                Spacer()
                Button(L10n.text("common.restore_defaults")) { draft = .standard; selected = nil }
            }
            Text(L10n.text(camera > 0 ? "layout.camera_help" : "layout.help"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            preview
            Text(L10n.text("layout.arrangement")).font(.system(size: 13, weight: .medium))
            HStack(alignment: .top, spacing: 10) {
                ForEach(CompactIslandLayout.Lane.allCases, id: \.rawValue) { lane in laneEditor(lane) }
            }.frame(height: 90)
            inspector
            Divider()
            Text(L10n.text("layout.components")).font(.system(size: 13, weight: .medium))
            ScrollView {
                LayoutChipFlow(spacing: 8) {
                    ForEach(CompactIslandLayout.Component.allCases) { component in
                        Button {
                            if draft.components.contains(component) { draft.hide(component); if selected == component { selected = nil } }
                            else { draft.move(component, to: .leading); selected = component }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: draft.components.contains(component) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(draft.components.contains(component) ? Color.accentColor : Color.secondary)
                                Text(component.label)
                            }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).font(.system(size: 12))
                        .highPriorityGesture(rearrangeGesture(component))
                        .accessibilityLabel(component.label)
                        .accessibilityValue(L10n.text(draft.components.contains(component) ? "layout.shown" : "layout.hidden"))
                    }
                }.padding(2)
            }.frame(maxHeight: .infinity)
            HStack {
                Text(L10n.text("layout.applies_on_save")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("layout.use_layout")) { layout = draft.normalized; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 840, height: 570)
        .coordinateSpace(name: "compact-editor")
        .onPreferenceChange(CompactEditorDropRegions.self) { dropRegions = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged {
                Text(dragged.label).font(.system(size: 11)).padding(8)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white).position(dragLocation).allowsHitTesting(false).accessibilityHidden(true)
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
        .frame(height: 92)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(L10n.text("layout.preview"))
    }
    private func laneEditor(_ lane: CompactIslandLayout.Lane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.label).font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(draft[lane]) { component in
                        Text(component.label).font(.system(size: 11)).fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 7)
                            .background(selected == component ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = component }
                            .gesture(rearrangeGesture(component))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selected = component }
                            .accessibilityLabel(component.label)
                        .background(dropRegion(lane, before: component))
                        .contextMenu {
                            Button(L10n.text("layout.hide")) { draft.hide(component); selected = nil }
                            ForEach(CompactIslandLayout.Lane.allCases, id: \.rawValue) { target in
                                Button(target.label) { draft.move(component, to: target) }
                            }
                        }
                    }
                    if draft[lane].isEmpty {
                        Text(L10n.text("layout.drop_here")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }.padding(.bottom, 6)
            }.scrollIndicators(.visible)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .background(dropRegion(lane, before: nil))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(dragged == nil ? 0 : 0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lane.label)
    }
    @ViewBuilder private var inspector: some View {
        if let selected, let lane = CompactIslandLayout.Lane.allCases.first(where: { draft[$0].contains(selected) }),
           let index = draft[lane].firstIndex(of: selected) {
            HStack(spacing: 12) {
                Text(selected.label).font(.system(size: 12, weight: .medium)).frame(width: 180, alignment: .leading)
                Picker(L10n.text("layout.position_lane"), selection: Binding(get: { lane }, set: { draft.move(selected, to: $0) })) {
                    ForEach(CompactIslandLayout.Lane.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }.frame(width: 180)
                Button { draft.shift(selected, by: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(index == 0).help(L10n.text("layout.earlier")).accessibilityLabel(L10n.text("layout.earlier"))
                Button { draft.shift(selected, by: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(index + 1 == draft[lane].count).help(L10n.text("layout.later")).accessibilityLabel(L10n.text("layout.later"))
                Button(L10n.text("layout.hide")) { draft.hide(selected); self.selected = nil }
                Spacer()
            }.frame(height: 30)
        } else {
            Text(L10n.text("layout.select_hint")).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 30)
        }
    }
    private func dropRegion(_ lane: CompactIslandLayout.Lane, before: CompactIslandLayout.Component?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CompactEditorDropRegions.self,
                value: [.init(lane: lane, before: before, frame: geometry.frame(in: .named("compact-editor")))])
        }
    }
    // A local gesture allows precise reordering without publishing a drag payload
    // outside this editor. Buttons retain ordinary clicks and keyboard actions.
    private func rearrangeGesture(_ component: CompactIslandLayout.Component) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("compact-editor"))
            .onChanged { value in dragged = component; dragLocation = value.location }
            .onEnded { value in
                defer { dragged = nil }
                guard let laneRegion = dropRegions.first(where: { $0.before == nil && $0.frame.contains(value.location) }) else { return }
                let chip = dropRegions.first(where: { $0.lane == laneRegion.lane && $0.before != nil && $0.frame.contains(value.location) })
                draft.move(component, to: laneRegion.lane, before: chip?.before)
                selected = component
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
private struct LayoutChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 150, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
