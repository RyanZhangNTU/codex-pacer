import SwiftUI
import PacerCore

/// Line one names the task and its speed, line two its state and model, so the
/// trailing column pairs a rate with the model that produced it. The panel's
/// choices can leave out readings or keep one line with the name and the
/// speed; a row that needs the user then shows its state there instead.
struct TaskRowView: View {
    let presentation: ActivityTaskRowPresentation
    let group: ActivityTaskGroup?
    private var activity: SessionActivity { presentation.activity }
    private var attention: PendingAttentionRequest.Kind? { presentation.attention }
    private var name: String { presentation.title }
    private var sourceName: String? { presentation.source }
    let now: Date
    let enabled: Bool
    private var unread: Bool { presentation.unread }
    let accent: Color
    private var cost: String? { presentation.cost }
    var costHelp: String? = nil
    /// The expanded panel's row style and fields; Overview keeps every reading.
    var options = ExpandedPanelOptions()
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A long title stops widening the panel here; a panel that other rows
    /// made wider still shows more of it.
    static let measuredTitleWidth: CGFloat = 200
    private var phase: ActivityPhase { presentation.phase }
    private var status: String { presentation.status }
    private var subagents: Int { presentation.subagents }
    private var subagentText: String {
        if activity.provider.opensApplicationForTasks { return activity.provider.taskOpenLabel }
        if activity.claudeCloud != nil { return L10n.text("claude.cloud.workers_help", subagents) }
        return L10n.text(subagents == 1 ? "activity.subagent_running" : "activity.subagents_running", subagents)
    }
    private var rate: OutputEstimate? { presentation.rate }
    private var turnTime: String? { presentation.turnTime }
    private var dimmed: Bool { presentation.dimmed }
    private var modelLabel: String { presentation.model }
    private var effortLabel: String? { presentation.effort }
    private var latencyText: String {
        L10n.text("performance.first_output", activity.firstTokenLatency.map { String(format: "%.1f s", $0) } ?? "—")
    }
    private var performanceText: String {
        let speed = rate.map { String(format: "%.1f t/s", $0.value) } ?? (phase == .running ? L10n.text("performance.awaiting_usage") : "—")
        // A cloud run's first output is only known when its turn ends.
        return activity.claudeCloud != nil && phase == .running ? speed : speed + "  ·  " + latencyText
    }
    private var color: Color { Self.color(presentation) }
    private var detailColor: Color { Self.detailColor(presentation) }
    private var face: TaskStatusIconNSView.Face { Self.face(presentation) }
    /// The icon's ink, shared with the Codex for Claude lines under a row.
    static func color(_ row: ActivityTaskRowPresentation) -> Color {
        let activity = row.activity
        if row.attention != nil { return PacerPalette.attention }
        if activity.turnFailed { return PacerPalette.danger }
        if activity.codexGoalPause != nil { return PacerPalette.paused }
        if row.dimmed { return PacerPalette.secondary }
        switch row.phase {
        case .waitingForInput: return PacerPalette.attention
        case .interrupted: return PacerPalette.paused
        case .running, .completed: return activity.provider.tint
        default: return PacerPalette.secondary
        }
    }
    static func detailColor(_ row: ActivityTaskRowPresentation) -> Color {
        if row.attention != nil || row.phase == .waitingForInput { return PacerPalette.attention }
        return row.activity.turnFailed ? PacerPalette.danger : PacerPalette.secondary
    }
    /// A working stage shows its glyph over an orb; a request for the user or
    /// an ending fills a disc, greyed once read; an unknown state draws a moon.
    static func face(_ row: ActivityTaskRowPresentation) -> TaskStatusIconNSView.Face {
        let symbol = row.symbol
        switch symbol {
        case .approval, .input, .completed, .interrupted, .failed: return .solid(symbol, read: row.dimmed)
        case .unknown: return .plain(symbol)
        default: return .working(symbol)
        }
    }
    private var progressRing: TaskProgressRing? { presentation.progressRing }

    var body: some View {
        Button(action: action) {
            rowContent(measuring: false)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .background {
            rowContent(measuring: true).fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ExpandedContentIdealWidth.self, value: geometry.size.width)
                })
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: TaskRowInteraction.hoverDuration), value: hovered)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        return [enabled ? openHelp : L10n.text("activity.no_link"), costHelp].compactMap { $0 }.joined(separator: " ")
    }

    var showsSubagentDots: Bool { options.rowFields.contains(.subagents) && !presentation.subagentDotStates.isEmpty }

    var accessibilityText: String {
        let state = [unread ? L10n.text("common.not_viewed") : nil, status, presentation.isCompacting ? nil : presentation.contextAccessibilityValue,
                     progressRing?.accessibilityText, turnTime,
                     showsSubagentDots ? presentation.subagentDotsAccessibility : (subagents > 0 ? subagentText : nil), presentation.delegatedCount > 0 ? presentation.delegatedCountText : nil]
        let model = [modelLabel, effortLabel.map { L10n.text("model.effort_help", $0) }].compactMap { $0 }.joined(separator: " ")
        return activity.provider.displayName + ", " + L10n.text("activity.row_accessibility", name,
            state.compactMap { $0 }.joined(separator: ", "), sourceName ?? L10n.text("common.local")) + ", " + model + (activity.claudeCloud == nil || rate != nil ? ", " + performanceText : "")
            + (presentation.costAccessibility.map { ", " + $0 } ?? "")
    }

    /// Rows of one line are this tall; two-line rows take 54 points.
    static func height(_ style: ExpandedPanelOptions.RowStyle) -> CGFloat { style == .oneLine ? 38 : 54 }
    private var oneLine: Bool { options.rowStyle == .oneLine }
    private var showsRate: Bool { options.shows(.rate) && (rate != nil || activity.claudeCloud == nil) }
    private var showsTime: Bool { options.shows(.turnTime) && turnTime != nil }
    private var showsCost: Bool { options.shows(.cost) && cost != nil }
    /// Attention, failure or context compaction replaces the
    /// readings in a one-line row.
    private var statusLeads: Bool { attention != nil || phase == .waitingForInput || activity.turnFailed || presentation.isCompacting }

    @ViewBuilder private func rowContent(measuring: Bool) -> some View {
        HStack(spacing: oneLine ? 8 : 10) {
            statusIcon(measuring: measuring)
            textLines(measuring: measuring)
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
    }

    func textLines(measuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TaskLineLayout(measuring: measuring, hasModel: false, hasTime: showsTime && !(oneLine && statusLeads)) { _, showTime in
                HStack(alignment: oneLine ? .center : .firstTextBaseline, spacing: oneLine ? 8 : 16) {
                    title(measuring: measuring)
                    if oneLine, presentation.delegatedCount > 0 { DelegatedCountChip(text: presentation.delegatedCountText) }
                    if oneLine, showsSubagentDots {
                        SubagentDotsView(presentation: presentation, limit: ActivityTaskRowPresentation.compactSubagentDotLimit)
                    }
                    if oneLine, statusLeads {
                        Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(detailColor).lineLimit(1).fixedSize()
                    } else if showsRate || showTime { rateLine(showTime: showTime) }
                }
            }
            if !oneLine {
                TaskLineLayout(measuring: measuring, hasModel: options.shows(.model), hasTime: false) { showModel, _ in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        statusLine.frame(maxWidth: measuring ? nil : .infinity, alignment: .leading)
                        if showsCost || showModel { modelLine(showModel: showModel) }
                    }
                }
            }
        }
    }

    private func title(measuring: Bool) -> some View {
        Text(name).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(dimmed ? PacerPalette.secondary : PacerPalette.primary).lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 48, maxWidth: measuring ? Self.measuredTitleWidth : .infinity, alignment: .leading)
    }

    /// The ring and the state share one icon, 28 points or 22 in a one-line
    /// row. The width probe draws nothing, so only the shown row keeps a
    /// task's motion.
    @ViewBuilder private func statusIcon(measuring: Bool) -> some View {
        let full = TaskStatusIconNSView.diameter, side = oneLine ? 22 : full
        if measuring {
            Color.clear.frame(width: side, height: side)
        } else {
            TaskStatusIconView(id: activity.id, ring: progressRing, face: face, contextFraction: presentation.contextLevel?.fraction,
                compactingSince: presentation.compactingSince, color: color, animates: !reduceMotion,
                completionPulseOnly: activity.provider == .codex)
                .frame(width: full, height: full)
                .scaleEffect(side / full)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }

    /// Local SDK/ACP rows name the app that started their session.
    private var openHelp: String {
        if activity.claudeCloud != nil { return L10n.text("claude.cloud.open_help") }
        if activity.sourceHostID != nil {
            return L10n.text(activity.provider == .claude ? "claude.open_remote_help" : "common.open_chat")
        }
        guard activity.provider == .claude || activity.launchedByEmbeddingApp else { return L10n.text("common.open_chat") }
        return sourceName.map { L10n.text("claude.open_host_help", $0) } ?? L10n.text("common.open_chat")
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(status).foregroundStyle(detailColor).lineLimit(1).layoutPriority(1)
            // Codex for Claude runs this Claude task holds.
            if presentation.delegatedCount > 0 { DelegatedCountChip(text: presentation.delegatedCountText) }
            if showsSubagentDots {
                SubagentDotsView(presentation: presentation)
            } else if subagents > 0, options.shows(.subagents) {
                HStack(spacing: 3) {
                    Image(systemName: "person.2").font(.system(size: 9, weight: .semibold))
                    Text(presentation.subagentText).monospacedDigit()
                }
                .foregroundStyle(PacerPalette.secondary).fixedSize()
            }
            if let source = sourceName, options.shows(.source) {
                HStack(spacing: 3) {
                    // Remote hosts get a server glyph; a local app is named as is.
                    if activity.sourceHostID != nil {
                        Image(systemName: activity.claudeCloud != nil ? "cloud" : "server.rack").font(.system(size: 9, weight: .semibold))
                    }
                    Text(ActivityTaskRowPresentation.middleTruncated(source, limit: 16))
                }
                .foregroundStyle(PacerPalette.secondary).lineLimit(1).fixedSize()
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func rateLine(showTime: Bool) -> some View {
        let showsRate = options.shows(.rate)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showsRate, let rate {
                Text(presentation.rateText ?? "").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rate.isFresh && !dimmed ? PacerPalette.primary : PacerPalette.secondary)
                Text(" t/s").font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
            } else if showsRate, activity.claudeCloud == nil, phase == .running {
                Text(L10n.text("performance.awaiting_usage")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PacerPalette.tertiary)
            }
            if showTime, let turnTime, options.shows(.turnTime) {
                if showsRate, rate != nil || (activity.claudeCloud == nil && phase == .running) {
                    Text(" · ").font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
                Text(turnTime).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(phase == .running ? PacerPalette.primary.opacity(0.78) : PacerPalette.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).fixedSize()
    }

    private func modelLine(showModel: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let cost, options.shows(.cost) {
                HStack(alignment: .center, spacing: 4) {
                    if presentation.peakCost {
                        Circle().fill(PacerPalette.attention).frame(width: 5, height: 5).accessibilityHidden(true)
                    }
                    Text(cost).foregroundStyle(PacerPalette.primary.opacity(0.86))
                }
                .padding(.trailing, 3)
            }
            if showModel, options.shows(.model) {
                Text(modelLabel)
                if let effortLabel { Text(effortLabel).opacity(0.62) }
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(activity.provider.tint)
        .opacity(dimmed ? 0.7 : 1).lineLimit(1).fixedSize()
    }
}

struct ExpandedContentIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
