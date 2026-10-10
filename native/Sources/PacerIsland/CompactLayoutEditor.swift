import SwiftUI
import PacerCore

/// The Collapsed Bar page's first card: the live preview, a lane strip shaped
/// like the bar (left wing, camera, right wing) for arranging components, and
/// the width choice. Turning components on or off lives in the grouped rows below.
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
    private var hasNotch: Bool { model.screenNotchSize.width > 0 && model.screenNotchSize.height > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("layout.preview")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L10n.text("common.restore_defaults")) { layout = .standard }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            IslandWidthControl(model: model, settings: $widthSettings, layout: layout,
                attached: attached, quotaPreview: quotaPreview)
            laneStrip
            Text(L10n.text("layout.help")).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            widthControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .coordinateSpace(name: "compact-editor")
        .onPreferenceChange(CompactEditorDropRegions.self) { dropRegions = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged {
                Label(dragged.shortLabel, systemImage: dragged.symbol).font(.system(size: 11, weight: .medium)).padding(8)
                    .background(accent, in: Capsule()).foregroundStyle(.black)
                    .position(dragLocation).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.locale, L10n.locale)
    }

    /// Mirrors the bar: the left lane hugs the left edge, the right lane the
    /// right edge, and the middle marks the camera when this screen has one.
    private var laneStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            laneEditor(.leading)
            VStack(spacing: 4) {
                if hasNotch {
                    Image(systemName: "camera.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
            }
            .frame(width: 28).padding(.vertical, 2)
            .accessibilityHidden(true)
            laneEditor(.trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(accent.opacity(dragged == nil ? 0 : 0.55), lineWidth: 1))
    }

    private func laneEditor(_ lane: CompactIslandLayout.Lane) -> some View {
        let alignment: HorizontalAlignment = lane == .leading ? .leading : .trailing
        let components = layout.visibleComponents(in: lane, providers: providers)
        return VStack(alignment: alignment, spacing: 8) {
            Text(lane.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if components.isEmpty {
                Text(L10n.text("layout.drop_here")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 5)
            } else {
                CompactChipFlow(alignment: alignment, spacing: 6) {
                    ForEach(components) { component in chip(component) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: Alignment(horizontal: alignment, vertical: .top))
        .contentShape(Rectangle()).background(dropRegion(lane, before: nil))
        .accessibilityElement(children: .contain).accessibilityLabel(lane.label)
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("settings.width_mode")).font(.system(size: 13))
                Spacer()
                Picker(L10n.text("settings.width_mode"), selection: $widthSettings.mode) {
                    Text(L10n.text("settings.width_adaptive")).tag(IslandWidthSettings.Mode.adaptive)
                    Text(L10n.text("settings.width_fixed")).tag(IslandWidthSettings.Mode.fixed)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if widthSettings.mode == .fixed {
                let range = IslandWidthSettings.range
                let fraction = (widthSettings.normalized.width - range.lowerBound) / (range.upperBound - range.lowerBound)
                HStack(spacing: 10) {
                    Text(L10n.text("settings.width_narrow"))
                    Slider(value: $widthSettings.width, in: range)
                        .accessibilityLabel(L10n.text("settings.width_mode"))
                        .accessibilityValue(L10n.text(fraction < 0.33 ? "settings.width_narrow" :
                            fraction > 0.66 ? "settings.width_wide" : "settings.width_medium"))
                    Text(L10n.text("settings.width_wide"))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(L10n.text(widthSettings.mode == .adaptive ? "settings.width_adaptive_help" : "settings.width_fixed_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ component: CompactIslandLayout.Component) -> some View {
        HStack(spacing: 4) {
            Label(component.shortLabel, systemImage: component.symbol)
                .labelStyle(CompactChipLabelStyle())
                .contentShape(Rectangle()).gesture(rearrangeGesture(component))
                .focusable().focusEffectDisabled().focused($focusedComponent, equals: component)
                .onKeyPress(.leftArrow) { layout.shift(component, by: -1, providers: providers); return .handled }
                .onKeyPress(.rightArrow) { layout.shift(component, by: 1, providers: providers); return .handled }
                .accessibilityLabel(component.label)
                .accessibilityAction(named: Text(L10n.text("layout.move_left"))) { layout.move(component, to: .leading) }
                .accessibilityAction(named: Text(L10n.text("layout.move_right"))) { layout.move(component, to: .trailing) }
            Button { layout.hide(component) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 14, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("layout.hide_component", component.label))
                .accessibilityLabel(L10n.text("layout.hide_component", component.label))
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(focusedComponent == component ? accent : Color.primary.opacity(0.1), lineWidth: 1))
        .opacity(dragged == component ? 0.4 : 1)
        .background(dropRegion(layout.leading.contains(component) ? .leading : .trailing, before: component))
        .contextMenu {
            Button(L10n.text("layout.move_left")) { layout.move(component, to: .leading) }
            Button(L10n.text("layout.move_right")) { layout.move(component, to: .trailing) }
            Button(L10n.text("layout.earlier")) { layout.shift(component, by: -1, providers: providers) }
            Button(L10n.text("layout.later")) { layout.shift(component, by: 1, providers: providers) }
        }
    }
    private func dropRegion(_ lane: CompactIslandLayout.Lane, before: CompactIslandLayout.Component?) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CompactEditorDropRegions.self,
                value: [.init(lane: lane, before: before, frame: geometry.frame(in: .named("compact-editor")))])
        }
    }
    /// Chips wrap onto rows, so a drop lands before the first chip to its right
    /// on the same row, or before the next row's first chip, or at the end.
    private func rearrangeGesture(_ component: CompactIslandLayout.Component) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("compact-editor"))
            .onChanged { value in dragged = component; dragLocation = value.location }
            .onEnded { value in
                defer { dragged = nil }
                let point = value.location
                guard let lane = dropRegions.first(where: { $0.before == nil && $0.frame.contains(point) })?.lane else { return }
                let chips = dropRegions.filter { $0.lane == lane && $0.before != nil }
                let row = chips.filter { abs($0.frame.midY - point.y) <= $0.frame.height / 2 + 3 }
                let before = row.sorted { $0.frame.midX < $1.frame.midX }.first { point.x < $0.frame.midX }?.before ??
                    chips.filter { $0.frame.minY > point.y }
                        .min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }?.before
                layout.move(component, to: lane, before: before)
            }
    }
}

/// One switch row per component, with its description; options that only
/// matter while it is shown appear directly beneath it.
struct CompactComponentToggle: View {
    let component: CompactIslandLayout.Component
    @Binding var layout: CompactIslandLayout

    var body: some View {
        Toggle(isOn: Binding(get: { layout.components.contains(component) }, set: { shown in
            if shown { layout.move(component, to: component.preferredLane) } else { layout.hide(component) }
        })) {
            HStack(spacing: 10) {
                Image(systemName: component.symbol)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.label)
                    Text(component.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }
    /// Leading space that lines an option up with the row's title text.
    static let optionInset: CGFloat = 36
}

private struct CompactChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            configuration.title.font(.system(size: 11, weight: .medium)).fixedSize()
        }
    }
}

/// Wraps chips onto rows aligned to the lane's own edge, so long lanes never clip.
private struct CompactChipFlow: Layout {
    var alignment: HorizontalAlignment
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append((index, size))
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([(index, size)], size.width, size.height))
            }
        }
        return rows
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
