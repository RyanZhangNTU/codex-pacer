import SwiftUI
import PacerCore

/// The Collapsed Bar page's preview: the bar on a desktop, drawn with the
/// island's own components and live values. Clicking a component selects it
/// for the settings beside the preview; dragging moves it within its side or
/// to the other side. A component with nothing to show right now keeps its
/// place as a faint label, so it can still be found and moved.
struct CompactLayoutEditor: View {
    @ObservedObject var model: IslandModel
    @Binding var layout: CompactIslandLayout
    let providers: Set<AgentProvider>
    var selection: Binding<CompactIslandLayout.Component?> = .constant(nil)
    @State private var dragged: CompactIslandLayout.Component?
    @State private var dragLocation = CGPoint.zero
    @State private var dropRegions: [CompactEditorDropRegion] = []
    @State private var hovered: CompactIslandLayout.Component?
    @FocusState private var focusedComponent: CompactIslandLayout.Component?
    @Environment(\.pacerAccent) private var accent
    private static let barHeight: CGFloat = 34
    private static let menuBarHeight: CGFloat = 24
    private var hasNotch: Bool { model.screenNotchSize.width > 0 && model.screenNotchSize.height > 0 }
    private var attached: Bool { model.isAttached }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            desk
            if model.sideDock != nil {
                Text(L10n.text("layout.strip_help")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "compact-editor")
        .onPreferenceChange(CompactEditorDropRegions.self) { dropRegions = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged {
                Label(dragged.shortLabel, systemImage: dragged.symbol).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(accent, in: Capsule()).foregroundStyle(.white)
                    .position(dragLocation).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.locale, L10n.locale)
    }

    /// A strip of desktop under a menu bar, with the bar where the island
    /// shows it: hanging from the top edge, or floating below the menu bar.
    private var desk: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: Self.menuBarHeight)
                .frame(maxHeight: .infinity, alignment: .top)
            bar.padding(.top, attached ? 0 : Self.menuBarHeight + 10)
        }
        .frame(maxWidth: .infinity).frame(height: 122)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(dragged == nil ? MainPalette.cardBorder : accent.opacity(0.6), lineWidth: dragged == nil ? 1 : 1.5))
    }

    private var bar: some View {
        HStack(spacing: 0) {
            laneEditor(.leading)
            camera
            laneEditor(.trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.barHeight)
        .background(Color.black, in: barShape)
        .environment(\.colorScheme, .dark)
    }

    private var barShape: AnyShape {
        attached ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
            : AnyShape(Capsule())
    }

    /// The camera's place on a notched screen; elsewhere a narrow gap.
    @ViewBuilder private var camera: some View {
        if attached && hasNotch {
            Circle().fill(Color(white: 0.09)).overlay(Circle().strokeBorder(Color(white: 0.16)))
                .frame(width: 8, height: 8).frame(width: 128).accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 18)
        }
    }

    /// A docked strip stacks the lanes, so they are named for where they show.
    private func title(_ lane: CompactIslandLayout.Lane) -> String {
        guard model.sideDock != nil else { return lane.label }
        return L10n.text(lane == .leading ? "layout.lane.strip_top" : "layout.lane.strip_bottom")
    }

    private func laneEditor(_ lane: CompactIslandLayout.Lane) -> some View {
        let components = layout.visibleComponents(in: lane, providers: providers)
        return HStack(spacing: attached ? 4 : 6) {
            if components.isEmpty {
                Text(L10n.text("layout.drop_here")).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            } else {
                ForEach(components) { component in chip(component) }
            }
        }
        .frame(minWidth: 64, minHeight: Self.barHeight, alignment: lane == .leading ? .leading : .trailing)
        .contentShape(Rectangle()).background(dropRegion(lane, before: nil))
        .accessibilityElement(children: .contain).accessibilityLabel(title(lane))
    }

    private func chip(_ component: CompactIslandLayout.Component) -> some View {
        let selected = selection.wrappedValue == component
        let showsLive = CompactIslandComponent.isVisible(component, model: model, showsStatus: layout.components.contains(.status))
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Group {
            if showsLive {
                CompactIslandComponent(model: model, component: component).allowsHitTesting(false)
            } else {
                Label(component.shortLabel, systemImage: component.symbol).labelStyle(CompactChipLabelStyle())
                    .frame(height: 24)
            }
        }
        .padding(.horizontal, 5)
        .background(selected ? accent.opacity(0.3) : hovered == component ? Color.white.opacity(0.1) : .clear, in: shape)
        .overlay(shape.strokeBorder(selected || focusedComponent == component ? accent : .clear, lineWidth: 1.5))
        .contentShape(shape)
        .opacity(dragged == component ? 0.35 : 1)
        .help(showsLive ? component.label : L10n.text("main.collapsed.nothing_now", component.label))
        .onHover { hovered = $0 ? component : (hovered == component ? nil : hovered) }
        .onTapGesture { selection.wrappedValue = component; focusedComponent = component }
        .gesture(rearrangeGesture(component))
        .focusable().focusEffectDisabled().focused($focusedComponent, equals: component)
        .onKeyPress(.leftArrow) { layout.shift(component, by: -1, providers: providers); return .handled }
        .onKeyPress(.rightArrow) { layout.shift(component, by: 1, providers: providers); return .handled }
        .onKeyPress(.delete) { layout.hide(component); return .handled }
        .background(dropRegion(layout.leading.contains(component) ? .leading : .trailing, before: component))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(component.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection.wrappedValue = component }
        .accessibilityAction(named: Text(L10n.text("layout.move_left"))) { layout.move(component, to: .leading) }
        .accessibilityAction(named: Text(L10n.text("layout.move_right"))) { layout.move(component, to: .trailing) }
        .accessibilityAction(named: Text(L10n.text("main.collapsed.remove"))) { layout.hide(component) }
        .contextMenu {
            Button(L10n.text("layout.move_left")) { layout.move(component, to: .leading) }
            Button(L10n.text("layout.move_right")) { layout.move(component, to: .trailing) }
            Button(L10n.text("layout.earlier")) { layout.shift(component, by: -1, providers: providers) }
            Button(L10n.text("layout.later")) { layout.shift(component, by: 1, providers: providers) }
            Divider()
            Button(L10n.text("main.collapsed.remove")) { layout.hide(component) }
        }
    }

    private func dropRegion(_ lane: CompactIslandLayout.Lane, before: CompactIslandLayout.Component?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CompactEditorDropRegions.self,
                value: [.init(lane: lane, before: before, frame: geometry.frame(in: .named("compact-editor")))])
        }
    }

    /// A drop lands in the side nearest the pointer, before the first
    /// component whose middle lies to its right, or at the end of that side.
    private func rearrangeGesture(_ component: CompactIslandLayout.Component) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("compact-editor"))
            .onChanged { value in
                dragged = component; dragLocation = value.location
                selection.wrappedValue = component
            }
            .onEnded { value in
                defer { dragged = nil }
                let point = value.location
                let lanes = dropRegions.filter { $0.before == nil }
                guard let lane = lanes.min(by: { distance(point, $0.frame) < distance(point, $1.frame) })?.lane else { return }
                let before = dropRegions.filter { $0.lane == lane && $0.before != nil }
                    .sorted { $0.frame.midX < $1.frame.midX }
                    .first { point.x < $0.frame.midX }?.before
                layout.move(component, to: lane, before: before)
            }
    }

    private func distance(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}

/// A component with nothing to show yet: its symbol and short name, faint.
private struct CompactChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .medium))
            configuration.title.font(.system(size: 11, weight: .medium)).fixedSize()
        }
        .foregroundStyle(Color.white.opacity(0.5))
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
