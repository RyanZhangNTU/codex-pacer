import SwiftUI
import PacerCore

struct TaskRowView: View {
    var attention: PendingAttentionRequest.Kind? = nil
    var group: ActivityTaskGroup? = nil
    let activity: SessionActivity
    let name: String
    let now: Date
    let enabled: Bool
    let unread: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var phase: ActivityPhase { group?.isRunning == true ? .running : group?.isWaiting == true ? .waitingForInput : activity.observedPhase(at: now) }
    private var detail: String {
        var base = phase == .completed ? L10n.text("activity.turn_finished") : activity.detail(at: now)
        if group?.isRunning == true, activity.phase != .running, !activity.turnFailed { base = L10n.text("activity.running_long") }
        if let attention {
            let prompt = L10n.text(attention == .approval ? "attention.approval" : "attention.input")
            base = phase == .running ? prompt + " · " + base : prompt
        }
        let count = group?.runningSubagentCount ?? 0
        return count > 0 ? base + " · " + L10n.text(count == 1 ? "activity.subagent_running" : "activity.subagents_running", count) : base
    }
    private var rate: OutputEstimate? { group?.displayedRate(at: now) ?? activity.displayedOutputEstimate(at: now) }
    private var elapsed: String? { Self.elapsedText(activity, phase: phase, now: now) }
    /// How long the current turn has run answers "is it stuck?" at a glance.
    static func elapsedText(_ activity: SessionActivity, phase: ActivityPhase, now: Date) -> String? {
        guard phase == .running, let start = activity.turnStartedAt, start <= now else { return nil }
        return CompactDuration.text(now.timeIntervalSince(start))
    }
    private var latencyText: String {
        L10n.text("performance.first_output", activity.firstTokenLatency.map { String(format: "%.1f s", $0) } ?? "—")
    }
    private var performanceText: String {
        (rate.map { String(format: "%.1f t/s", $0.value) } ?? L10n.text("performance.awaiting_usage")) + "  ·  " + latencyText
    }
    private var performanceHelp: String {
        if activity.provider == .claude {
            let definition = L10n.text("claude.performance.rate_help") + "\n" + L10n.text("claude.performance.ttft_help")
            return group.map { $0.members.count > 1 ? L10n.text("performance.group_help") + "\n" + definition : definition } ?? definition
        }
        let latency = L10n.text("performance.latency_help")
        if let group, group.members.count > 1 { return L10n.text("performance.group_help") + "\n" + latency }
        if activity.displayedRateIsEstimated(at: now) { return L10n.text("performance.retained_help") + "\n" + latency }
        guard let sample = activity.responsePerformance else { return L10n.text("performance.awaiting_usage_help") + "\n" + latency }
        return L10n.text("performance.response_help", sample.outputTokens, sample.duration) + "\n" + latency
    }
    private var color: Color {
        if attention != nil { return PacerPalette.attention }
        if activity.turnFailed { return PacerPalette.danger }
        switch phase {
        case .waitingForInput: return PacerPalette.attention
        case .interrupted: return PacerPalette.paused
        case .running, .completed: return activity.provider.tint
        default: return PacerPalette.secondary
        }
    }
    private var detailColor: Color {
        if attention != nil || phase == .waitingForInput { return PacerPalette.attention }
        return activity.turnFailed ? PacerPalette.danger : PacerPalette.secondary
    }
    private var symbol: String {
        if attention == nil, group?.isRunning == true, activity.phase != .running { return StatusSymbols.thinking }
        return StatusSymbols.symbol(for: activity, attention: attention)
    }

    var body: some View {
        Button(action: action) {
            rowContent
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .background {
            rowContent.fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TaskRowIdealWidth.self, value: geometry.size.width)
                })
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(enabled ? [L10n.text(activity.provider == .claude && activity.sourceHostID != nil ? "claude.open_remote_help" : "common.open_chat"),
            activity.modelName].compactMap { $0 }.joined(separator: " · ") : L10n.text("activity.no_link"))
        .accessibilityLabel(activity.provider.displayName + ", " + L10n.text("activity.row_accessibility", name,
            [detail, elapsed].compactMap { $0 }.joined(separator: ", "), activity.sourceHost ?? L10n.text("common.local")) + ", " + performanceText)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            StatusTile(symbol: symbol, tint: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(PacerPalette.primary).lineLimit(1)
                    if unread {
                        Circle().fill(color).frame(width: 6, height: 6).accessibilityLabel(L10n.text("common.not_viewed"))
                    }
                }
                HStack(spacing: 5) {
                    Text(detail).foregroundStyle(detailColor).lineLimit(1).layoutPriority(1)
                    if let elapsed {
                        separator
                        Text(elapsed).foregroundStyle(PacerPalette.primary.opacity(0.78)).monospacedDigit().fixedSize()
                    }
                    separator
                    Text(activity.provider.displayName).foregroundStyle(activity.provider.tint).fixedSize()
                    if let host = activity.sourceHost {
                        separator
                        Text(host).foregroundStyle(PacerPalette.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 12)
            metrics
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
    }

    private var separator: some View {
        Text("·").foregroundStyle(PacerPalette.tertiary).accessibilityHidden(true)
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let rate {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", rate.value)).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rate.isFresh ? PacerPalette.primary : PacerPalette.secondary)
                    Text("t/s").font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
            } else {
                Text(L10n.text("performance.awaiting_usage")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PacerPalette.tertiary)
            }
            Text(latencyText).font(.system(size: 10)).foregroundStyle(PacerPalette.tertiary)
        }
        .monospacedDigit().lineLimit(1).fixedSize()
        .help(performanceHelp)
    }
}

struct TaskRowIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
