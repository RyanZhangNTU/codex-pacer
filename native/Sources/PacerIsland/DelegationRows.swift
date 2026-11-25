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

/// One run: its icon (state and progress ring), Claude's label, then speed,
/// time, model and effort, always on the line and reaching its end; no hover
/// card. While it runs, hovering lays Stop over the line's end, and the
/// numbers under it fade out.
struct DelegationLineView: View {
    let presentation: ActivityTaskRowPresentation
    let enabled: Bool
    let open: () -> Void
    let stop: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var phase: ActivityPhase { presentation.phase }

    /// The label and state stop widening the panel here, as on Windows.
    static let measuredLabelWidth: CGFloat = 220
    /// What surrounds a line's content: the rail and its inset before it, the margins after it.
    /// Stop takes no room of its own.
    private static let outerWidth: CGFloat = IslandMetrics.rowInset + 13 + 12 + 2 + 6
    /// Stop's size, and how far the numbers fade before it.
    private static let stopSize: CGFloat = 20, fadeWidth: CGFloat = 10
    private var showsStop: Bool { hovered && presentation.canStopDelegation }

    var body: some View {
        Button(action: open) { content(measuring: false) }
            .buttonStyle(.plain).disabled(!enabled)
            .mask { fade }
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(L10n.text(enabled ? "common.open_chat" : "activity.no_link"))
            // VoiceOver reaches Stop without hovering, as an action of the line.
            .accessibilityActions {
                if presentation.canStopDelegation { Button(L10n.text("delegation.stop"), action: stop) }
            }
            .overlay(alignment: .trailing) { if showsStop { stopButton.transition(.opacity) } }
            .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
        .background {
            // The panel widens to show a run's state, like a task row's title.
            content(measuring: true).fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ExpandedContentIdealWidth.self, value: geometry.size.width + Self.outerWidth)
                })
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: TaskRowInteraction.hoverDuration), value: hovered)
    }

    /// The width probe draws no icon, so only the shown line keeps the run's motion.
    private func content(measuring: Bool) -> some View {
        HStack(spacing: 8) {
            if measuring {
                Color.clear.frame(width: 20, height: 20)
            } else {
                TaskStatusIconView(id: presentation.activity.id, ring: presentation.progressRing, face: TaskRowView.face(presentation),
                                   color: TaskRowView.color(presentation), animates: !reduceMotion, completionPulseOnly: true)
                    .frame(width: TaskStatusIconNSView.diameter, height: TaskStatusIconNSView.diameter)
                    .scaleEffect(20 / TaskStatusIconNSView.diameter)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            Text(presentation.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(presentation.dimmed ? PacerPalette.secondary : PacerPalette.primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: measuring ? Self.measuredLabelWidth : .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 2).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// Speed and time as on a task row, then the model in Codex's color.
    private var trailing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let rate = presentation.rateText {
                Text(rate).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(presentation.rate?.isFresh == true && !presentation.dimmed ? PacerPalette.primary : PacerPalette.secondary)
                Text(presentation.turnTime != nil ? " t/s · " : " t/s  ").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PacerPalette.secondary)
            }
            if let time = presentation.turnTime {
                Text(time + "  ").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(phase == .running ? PacerPalette.primary.opacity(0.78) : PacerPalette.secondary)
            }
            Text(presentation.model + (presentation.effort.map { " " + $0 } ?? ""))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(AgentProvider.codex.tint)
                .opacity(presentation.dimmed ? 0.7 : 1)
        }
        .monospacedDigit().lineLimit(1).fixedSize()
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
