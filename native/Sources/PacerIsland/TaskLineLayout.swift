import SwiftUI
import PacerCore

/// Try each set of readings with the title at its minimum. Once a variant
/// fits, give the title all the remaining space. The panel's independent
/// ideal-width probe always measures the full variant.
struct TaskLineLayout<Content: View>: View {
    let measuring: Bool
    let hasModel: Bool
    let hasTime: Bool
    @ViewBuilder var content: (_ model: Bool, _ time: Bool) -> Content

    var body: some View {
        if measuring || (!hasModel && !hasTime) { content(hasModel, hasTime) }
        else {
            ViewThatFits(in: .horizontal) {
                if hasModel { MinimumLineWidth { content(true, hasTime) } }
                if hasTime { MinimumLineWidth { content(false, true) } }
                content(false, false)
            }
        }
    }
}

/// ViewThatFits normally asks for ideal widths. For its fit test only, ask
/// the row how far it can shrink with its tags and readings at full size.
struct MinimumLineWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.init(width: proposal.width ?? 0, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Shared rail content and width probe for subagents and Codex for Claude.
struct ChildTaskLine: View {
    let row: ActivityTaskRowPresentation
    /// The text after the tags; a run line uses its row's title.
    var title: String? = nil
    let typeTag: String?
    var nameTag: String? = nil
    let active: Bool
    let rate: String?
    let fresh: Bool
    var status: String? = nil
    /// A waiting or failed state keeps its color after the line ends.
    var statusInk: Color? = nil
    let time: String?
    let model: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let measuredTitleWidth: CGFloat = 220
    private static let tagWidthLimit: CGFloat = 120
    private static let railInsets: CGFloat = IslandMetrics.rowInset + 13 + 12 + 6

    var body: some View {
        content(measuring: false)
            .background {
                content(measuring: true).fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ExpandedContentIdealWidth.self, value: geometry.size.width + Self.railInsets)
                    })
                    .hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
    }

    private func content(measuring: Bool) -> some View {
        HStack(spacing: 8) {
            if measuring { Color.clear.frame(width: 20, height: 20) }
            else {
                TaskStatusIconView(id: row.activity.id, ring: row.progressRing, face: TaskRowView.face(row),
                                   contextFraction: row.contextLevel?.fraction, compactingSince: row.compactingSince,
                                   color: TaskRowView.color(row), animates: !reduceMotion, completionPulseOnly: true)
                    .frame(width: TaskStatusIconNSView.diameter, height: TaskStatusIconNSView.diameter)
                    .scaleEffect(20 / TaskStatusIconNSView.diameter)
                    .frame(width: 20, height: 20).accessibilityHidden(true)
            }
            TaskLineLayout(measuring: measuring, hasModel: model != nil, hasTime: time != nil) { showModel, showTime in
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if let typeTag {
                            let tint = active ? row.activity.provider.tint : PacerPalette.secondary
                            tag(typeTag, ink: tint, fill: tint.opacity(0.16))
                        }
                        if let nameTag { tag(nameTag, ink: PacerPalette.secondary, fill: PacerPalette.fill) }
                        Text(title ?? row.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(active ? PacerPalette.primary : PacerPalette.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 48, maxWidth: measuring ? Self.measuredTitleWidth : .infinity, alignment: .leading)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        let status = row.isCompacting ? row.status : self.status
                        if let rate {
                            Text(rate + " t/s").fontWeight(.semibold)
                                .foregroundStyle(active && fresh ? PacerPalette.primary : PacerPalette.secondary)
                        }
                        if let status {
                            if rate != nil { Text(" · ") }
                            Text(status).foregroundStyle(statusInk ?? PacerPalette.secondary)
                        }
                        if showTime, let time {
                            if rate != nil || status != nil { Text(" · ") }
                            Text(time)
                        }
                        if showModel, let model {
                            if rate != nil || status != nil || (showTime && time != nil) { Text(" · ") }
                            Text(model).foregroundStyle(active ? row.activity.provider.tint : PacerPalette.secondary)
                        }
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                    .monospacedDigit().lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, ink: Color, fill: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).frame(maxWidth: Self.tagWidthLimit).frame(height: 15)
            .background(fill, in: Capsule()).fixedSize()
    }
}
