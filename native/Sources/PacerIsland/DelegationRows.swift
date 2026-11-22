import SwiftUI
import PacerCore

/// "Codex 2" after a Claude task's state: the Codex for Claude runs it holds.
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
/// task's own row. Clicking a line opens the Claude task, like its row.
struct DelegationList: View {
    let rows: [ActivityTaskRowPresentation]
    let enabled: Bool
    let open: () -> Void
    let stop: (SessionActivity) -> Void
    /// Each run takes one 30-point line; the rail ends 4 points below the last.
    static let lineHeight: CGFloat = 30, railBottom: CGFloat = 4
    static func height(_ count: Int) -> CGFloat { count == 0 ? 0 : CGFloat(count) * lineHeight + railBottom }

    var body: some View {
        VStack(spacing: 0) {
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

/// One run: its icon with the ring, Claude's label and the run's state, then
/// speed, time, model and effort. Stop appears on hover while it runs.
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
    /// What surrounds a line's content: the rail and its inset before it, Stop and the margins after it.
    private static let outerWidth: CGFloat = IslandMetrics.rowInset + 13 + 12 + 4 + 20 + 2 + 6

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) { content(measuring: false) }
                .buttonStyle(.plain).disabled(!enabled)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(L10n.text(enabled ? "common.open_chat" : "activity.no_link"))
                // VoiceOver reaches Stop without hovering, as an action of the line.
                .accessibilityActions {
                    if presentation.canStopDelegation { Button(L10n.text("delegation.stop"), action: stop) }
                }
            if presentation.canStopDelegation {
                stopButton
            } else {
                Color.clear.frame(width: 20, height: 20).accessibilityHidden(true)
            }
        }
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
            (Text(presentation.title).font(.system(size: 12, weight: .semibold))
                .foregroundColor(presentation.dimmed ? PacerPalette.secondary : PacerPalette.primary)
             + Text("  " + presentation.status).font(.system(size: 11, weight: .medium))
                .foregroundColor(TaskRowView.detailColor(presentation)))
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

    /// Shown on hover; VoiceOver uses the line's Stop action instead.
    private var stopButton: some View {
        Button(action: stop) {
            ZStack {
                Circle().fill(PacerPalette.hover)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(PacerPalette.primary).frame(width: 7, height: 7)
            }
            .frame(width: 20, height: 20).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        .help(L10n.text("delegation.stop"))
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        let model = [presentation.model, presentation.effort.map { L10n.text("model.effort_help", $0) }].compactMap { $0 }.joined(separator: " ")
        let speed = presentation.rateText.map { $0 + " t/s" }
        return [AgentProvider.codex.displayName, presentation.title, presentation.status, presentation.progressRing?.accessibilityText,
                presentation.turnTime, speed, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
