import SwiftUI
import PacerCore

/// A task's subagents as dots after its state: lit while running, the
/// attention color while one waits for the user, the danger color if one
/// failed, grey once done.
struct SubagentDotsView: View {
    let presentation: ActivityTaskRowPresentation
    /// A one-line row has less room than a two-line one.
    var limit = ActivityTaskRowPresentation.subagentDotLimit

    static func color(_ dot: ActivityTaskRowPresentation.SubagentDot, provider: AgentProvider) -> Color {
        switch dot {
        case .running: return provider.tint
        case .attention: return PacerPalette.attention
        case .failed: return PacerPalette.danger
        case .completed: return PacerPalette.tertiary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2").font(.system(size: 9, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                .padding(.trailing, 1)
            let dots = presentation.subagentDots(limit: limit)
            ForEach(Array(dots.shown.enumerated()), id: \.offset) { _, dot in
                Circle().fill(Self.color(dot, provider: presentation.activity.provider)).frame(width: 5, height: 5)
            }
            if dots.more > 0 {
                Text("+\(dots.more)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(PacerPalette.secondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.subagentDotsAccessibility)
    }
}

/// While a subagent runs or needs attention, the rail shows up to three children.
/// The folded line counts the others. Clicking any line opens the task.
struct SubagentList: View {
    let lines: [ActivityTaskRowPresentation.SubagentLine]
    var folded: ActivityTaskRowPresentation.FoldedSubagents? = nil
    let enabled: Bool
    let open: () -> Void
    static let lineHeight: CGFloat = DelegationList.lineHeight, foldedHeight: CGFloat = DelegationList.foldedHeight,
               railBottom: CGFloat = DelegationList.railBottom
    static func height(_ count: Int, folded: Bool = false) -> CGFloat {
        count == 0 && !folded ? 0 : CGFloat(count) * lineHeight + (folded ? foldedHeight : 0) + railBottom
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lines, id: \.row.activity.id) { line in
                SubagentLineView(line: line, enabled: enabled, open: open).frame(height: Self.lineHeight)
            }
            if let folded {
                FoldedRunsLine(text: folded.text, enabled: enabled, open: open).frame(height: Self.foldedHeight)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(PacerPalette.tertiary.opacity(0.7)).frame(width: 1.5) }
        .padding(.leading, IslandMetrics.rowInset + 13).padding(.trailing, 6).padding(.bottom, Self.railBottom)
    }
}

/// One subagent: its icon and progress ring, its label, then its speed while
/// it writes and its time, or how it ended.
struct SubagentLineView: View {
    let line: ActivityTaskRowPresentation.SubagentLine
    let enabled: Bool
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var row: ActivityTaskRowPresentation { line.row }

    private var statusInk: Color? {
        switch line.state {
        case .approval, .input: return PacerPalette.attention
        case .failed: return PacerPalette.danger
        default: return nil
        }
    }

    var body: some View {
        Button(action: open) {
            ChildTaskLine(row: row, typeTag: line.typeTag, nameTag: line.nameTag, active: line.isActive,
                rate: line.rateText, fresh: line.rateIsFresh, status: line.statusText, statusInk: statusInk, time: line.time, model: line.model)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: TaskRowInteraction.hoverDuration), value: hovered)
        .accessibilityLabel(line.accessibilityText)
        .accessibilityHint(L10n.text(enabled ? "common.open_chat" : "activity.no_link"))
    }
}
