import SwiftUI
import PacerCore

/// Line one names the task and its speed, line two its state and model, so the
/// trailing column pairs a rate with the model that produced it.
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
    /// DeepSeek's estimated cost of this turn, when shown.
    private var cost: Double? { presentation.cost == nil ? nil : activity.turnCost }
    /// The turn was billed at the doubled peak price, and the task's spend today.
    var costDetail: (peak: Bool, help: String)? = nil
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
        if activity.claudeCloud != nil { return L10n.text("claude.cloud.workers_help", subagents) }
        return L10n.text(subagents == 1 ? "activity.subagent_running" : "activity.subagents_running", subagents)
    }
    private var rate: OutputEstimate? { presentation.rate }
    private var turnTime: String? { presentation.turnTime }
    static func turnTimeText(_ activity: SessionActivity, phase: ActivityPhase, now: Date) -> String? {
        ActivityTaskRowPresentation.turnTimeText(activity, phase: phase, now: now)
    }
    static func isDimmed(phase: ActivityPhase, unread: Bool, attention: Bool, failed: Bool) -> Bool {
        ActivityTaskRowPresentation.isDimmed(phase: phase, unread: unread, attention: attention, failed: failed)
    }
    private var dimmed: Bool { presentation.dimmed }
    private var modelLabel: String { presentation.model }
    private var effortLabel: String? { presentation.effort }
    private var latencyText: String {
        L10n.text("performance.first_output", activity.firstTokenLatency.map { String(format: "%.1f s", $0) } ?? "—")
    }
    private var performanceText: String {
        let speed = rate.map { String(format: "%.1f t/s", $0.value) } ?? L10n.text("performance.awaiting_usage")
        // A cloud run's first output is only known when its turn ends.
        return activity.claudeCloud != nil && phase == .running ? speed : speed + "  ·  " + latencyText
    }
    private var color: Color {
        if attention != nil { return PacerPalette.attention }
        if activity.turnFailed { return PacerPalette.danger }
        if dimmed { return PacerPalette.secondary }
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
    private var symbol: String { StatusSymbols.symbol(presentation.symbol) }

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
        .accessibilityHint(enabled ? openHelp : L10n.text("activity.no_link"))
    }

    private var accessibilityText: String {
        let state = [unread ? L10n.text("common.not_viewed") : nil, status, turnTime, subagents > 0 ? subagentText : nil]
        let model = [modelLabel, effortLabel.map { L10n.text("model.effort_help", $0) }].compactMap { $0 }.joined(separator: " ")
        return activity.provider.displayName + ", " + L10n.text("activity.row_accessibility", name,
            state.compactMap { $0 }.joined(separator: ", "), sourceName ?? L10n.text("common.local")) + ", " + model + (activity.claudeCloud == nil || rate != nil ? ", " + performanceText : "")
            + (cost.map { ", " + L10n.text("deepseek.turn_cost_accessibility", DeepSeekWallet.turnAmount($0)) } ?? "")
    }

    private func rowContent(measuring: Bool) -> some View {
        HStack(spacing: 10) {
            StatusGlyph(symbol: symbol, tint: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dimmed ? PacerPalette.secondary : PacerPalette.primary).lineLimit(1)
                        .frame(maxWidth: measuring ? Self.measuredTitleWidth : .infinity, alignment: .leading)
                    rateLine
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    statusLine.frame(maxWidth: measuring ? nil : .infinity, alignment: .leading)
                    modelLine
                }
            }
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
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
            if subagents > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "person.2").font(.system(size: 9, weight: .semibold))
                    Text(presentation.subagentText).monospacedDigit()
                }
                .foregroundStyle(PacerPalette.secondary).fixedSize()
            }
            if let source = sourceName {
                HStack(spacing: 3) {
                    // Remote hosts get a server glyph; a local app is named as is.
                    if activity.sourceHostID != nil {
                        Image(systemName: activity.claudeCloud != nil ? "cloud" : "server.rack").font(.system(size: 9, weight: .semibold))
                    }
                    Text(Self.middleTruncated(source, limit: 16))
                }
                .foregroundStyle(PacerPalette.secondary).lineLimit(1).fixedSize()
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var rateLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let rate {
                Text(presentation.rateText ?? "").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rate.isFresh && !dimmed ? PacerPalette.primary : PacerPalette.secondary)
                Text(" t/s").font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
            } else if activity.claudeCloud == nil {
                Text(L10n.text("performance.awaiting_usage")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PacerPalette.tertiary)
            }
            if let turnTime {
                if rate != nil || activity.claudeCloud == nil {
                    Text(" · ").font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
                Text(turnTime).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(phase == .running ? PacerPalette.primary.opacity(0.78) : PacerPalette.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).fixedSize()
    }

    private var modelLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let cost {
                HStack(alignment: .center, spacing: 4) {
                    if costDetail?.peak == true {
                        Circle().fill(PacerPalette.attention).frame(width: 5, height: 5).accessibilityHidden(true)
                    }
                    Text(DeepSeekWallet.turnAmount(cost)).foregroundStyle(PacerPalette.primary.opacity(0.86))
                }
                .padding(.trailing, 3)
            }
            Text(modelLabel)
            if let effortLabel { Text(effortLabel).opacity(0.62) }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(activity.provider.tint)
        .opacity(dimmed ? 0.7 : 1).lineLimit(1).fixedSize()
    }

    static func shortened(_ text: String, limit: Int) -> String { ActivityTaskRowPresentation.shortened(text, limit: limit) }
    static func middleTruncated(_ text: String, limit: Int) -> String { ActivityTaskRowPresentation.middleTruncated(text, limit: limit) }
}

struct ExpandedContentIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
