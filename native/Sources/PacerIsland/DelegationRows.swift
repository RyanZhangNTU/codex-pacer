import SwiftUI
import PacerCore

/// "Codex 2" after a Claude task's state: its Codex for Claude runs still running.
struct DelegatedCountChip: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(AgentProvider.codex.tint)
            .padding(.horizontal, 6).frame(height: 14)
            .background(Capsule().fill(AgentProvider.codex.tint.opacity(0.16)))
            .lineLimit(1).fixedSize()
            .accessibilityHidden(true)
    }
}

/// A Claude task's Codex for Claude runs, one line each, on a rail under the
/// task's own row: every running run and the most recent ended ones, three
/// lines at most, with the older ended runs folded into one short line above
/// them. Clicking any line opens the Claude task, like its row.
struct DelegationList: View {
    let rows: [ActivityTaskRowPresentation]
    var folded: ActivityTaskRowPresentation.FoldedDelegations? = nil
    let enabled: Bool
    let open: () -> Void
    let stop: (SessionActivity) -> Void
    /// Each run takes one 30-point line, the folded runs a 22-point one; the rail ends 4 points below the last.
    static let lineHeight: CGFloat = 30, foldedHeight: CGFloat = 22, railBottom: CGFloat = 4
    static func height(_ count: Int, folded: Bool = false) -> CGFloat {
        count == 0 && !folded ? 0 : CGFloat(count) * lineHeight + (folded ? foldedHeight : 0) + railBottom
    }

    var body: some View {
        VStack(spacing: 0) {
            if let folded {
                FoldedRunsLine(text: folded.text, enabled: enabled, open: open).frame(height: Self.foldedHeight)
            }
            ForEach(rows, id: \.activity.id) { row in
                DelegationLineView(presentation: row, enabled: enabled, open: open, stop: { stop(row.activity) })
                    .frame(height: Self.lineHeight)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(PacerPalette.tertiary.opacity(0.7)).frame(width: 1.5) }
        .padding(.leading, IslandMetrics.rowInset + 13).padding(.trailing, 6).padding(.bottom, Self.railBottom)
    }
}

/// The older ended runs as one quiet line: how many, and how many failed.
struct FoldedRunsLine: View {
    let text: String
    let enabled: Bool
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PacerPalette.tertiary).frame(width: 20).accessibilityHidden(true)
                Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 2).padding(.trailing, 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: TaskRowInteraction.hoverDuration), value: hovered)
        .accessibilityLabel(text)
        .accessibilityHint(L10n.text(enabled ? "common.open_chat" : "activity.no_link"))
    }
}

/// Hovering a running line lays Stop over its trailing readings.
struct DelegationLineView: View {
    let presentation: ActivityTaskRowPresentation
    let enabled: Bool
    let open: () -> Void
    let stop: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stop's size, and how far the numbers fade before it.
    private static let stopSize: CGFloat = 20, fadeWidth: CGFloat = 10
    private var showsStop: Bool { hovered && presentation.canStopDelegation }

    var body: some View {
        Button(action: open) {
            ChildTaskLine(row: presentation, typeTag: presentation.modeTag,
                active: ActivityTaskRowPresentation.isRunningDelegation(presentation.activity),
                rate: presentation.rateText, fresh: presentation.rate?.isFresh == true,
                time: presentation.turnTime, model: presentation.model + (presentation.effort.map { " " + $0 } ?? ""))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .mask { fade }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(L10n.text(enabled ? "common.open_chat" : "activity.no_link"))
        // VoiceOver reaches Stop without hovering, as an action of the line.
        .accessibilityActions {
            if presentation.canStopDelegation { Button(L10n.text("delegation.stop"), action: stop) }
        }
        .overlay(alignment: .trailing) { if showsStop { stopButton.transition(.opacity) } }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: TaskRowInteraction.hoverDuration), value: hovered)
    }

    /// The whole line, or with Stop showing, the line fading out just before it.
    private var fade: some View {
        HStack(spacing: 0) {
            Rectangle()
            if showsStop {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Self.fadeWidth)
                Color.clear.frame(width: Self.stopSize)
            }
        }
    }

    /// Shown on hover over the line's end, with no tooltip; VoiceOver uses the line's Stop action instead.
    private var stopButton: some View {
        Button(action: stop) {
            ZStack {
                Circle().fill(PacerPalette.hover)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(PacerPalette.primary).frame(width: 7, height: 7)
            }
            .frame(width: Self.stopSize, height: Self.stopSize).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        let speed = presentation.rateText.map { $0 + " t/s" }
        return ([AgentProvider.codex.displayName, presentation.title, presentation.progressRing?.accessibilityText, presentation.turnTime, speed]
            .compactMap { $0 } + presentation.delegationDetail.map { $0.label + " " + $0.value })
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
