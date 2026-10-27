import SwiftUI
import PacerCore

/// Line one names the task and its speed, line two its state and model, so the
/// trailing column pairs a rate with the model that produced it.
struct TaskRowView: View {
    var attention: PendingAttentionRequest.Kind? = nil
    var group: ActivityTaskGroup? = nil
    let activity: SessionActivity
    let name: String
    let sourceName: String?
    let now: Date
    let enabled: Bool
    let unread: Bool
    let accent: Color
    /// DeepSeek's estimated cost of this turn, when shown.
    var cost: Double? = nil
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A long title stops widening the panel here; a panel that other rows
    /// made wider still shows more of it.
    static let measuredTitleWidth: CGFloat = 200
    private var phase: ActivityPhase { group?.isRunning == true ? .running : group?.isWaiting == true ? .waitingForInput : activity.observedPhase(at: now) }
    private var status: String {
        var base = phase == .completed ? L10n.text("activity.turn_finished") : activity.detail(at: now)
        if group?.isRunning == true, activity.phase != .running, !activity.turnFailed { base = L10n.text("activity.running_long") }
        guard let attention else { return base }
        let prompt = L10n.text(attention == .approval ? "attention.approval" : "attention.input")
        guard phase == .running else { return prompt }
        switch activity.phase == .running ? activity.stage : nil {
        case .tool?: return prompt + " · " + L10n.text("activity.tool_compact")
        case .responding?: return prompt + " · " + L10n.text("activity.responding_compact")
        default: return prompt + " · " + base
        }
    }
    private var subagents: Int { group?.runningSubagentCount ?? 0 }
    private var rate: OutputEstimate? { group?.displayedRate(at: now) ?? activity.displayedOutputEstimate(at: now) }
    private var turnTime: String? { Self.turnTimeText(activity, phase: phase, now: now) }
    /// A running turn counts up; an ended turn keeps how long it took.
    static func turnTimeText(_ activity: SessionActivity, phase: ActivityPhase, now: Date) -> String? {
        guard let start = activity.turnStartedAt else { return nil }
        if phase == .running { return start <= now ? CompactDuration.text(now.timeIntervalSince(start)) : nil }
        guard [.completed, .interrupted].contains(phase), [.completed, .interrupted].contains(activity.phase),
              let end = activity.phaseChangedAt, end >= start else { return nil }
        return CompactDuration.text(end.timeIntervalSince(start))
    }
    /// A read ending steps back so running, waiting and unread rows lead.
    /// Failures stay red.
    static func isDimmed(phase: ActivityPhase, unread: Bool, attention: Bool, failed: Bool) -> Bool {
        !unread && !attention && !failed && [.completed, .interrupted].contains(phase)
    }
    private var dimmed: Bool { Self.isDimmed(phase: phase, unread: unread, attention: attention != nil, failed: activity.turnFailed) }
    private var modelLabel: String {
        activity.modelName.map { Self.shortened(ModelDisplay.name($0), limit: 22) } ?? activity.provider.displayName
    }
    private var effortLabel: String? {
        activity.modelName == nil ? nil : activity.reasoningEffort.flatMap { ModelDisplay.effortLabel($0) }
    }
    private var latencyText: String {
        L10n.text("performance.first_output", activity.firstTokenLatency.map { String(format: "%.1f s", $0) } ?? "—")
    }
    private var performanceText: String {
        (rate.map { String(format: "%.1f t/s", $0.value) } ?? L10n.text("performance.awaiting_usage")) + "  ·  " + latencyText
    }
    private var performanceHelp: String {
        let definition: String
        if activity.provider == .claude {
            definition = L10n.text("claude.performance.rate_help") + "\n" + L10n.text("claude.performance.ttft_help")
        } else if let group, group.members.count > 1 {
            definition = L10n.text("performance.latency_help")
        } else if activity.displayedRateIsEstimated(at: now) {
            definition = L10n.text("performance.retained_help") + "\n" + L10n.text("performance.latency_help")
        } else if let sample = activity.responsePerformance {
            definition = L10n.text("performance.response_help", sample.outputTokens, sample.duration) + "\n" + L10n.text("performance.latency_help")
        } else {
            definition = L10n.text("performance.awaiting_usage_help") + "\n" + L10n.text("performance.latency_help")
        }
        let total = group.map { $0.members.count > 1 ? L10n.text("performance.group_help") + "\n" : "" } ?? ""
        return latencyText + "\n" + total + definition
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
    private var symbol: String {
        if attention == nil, group?.isRunning == true, activity.phase != .running { return StatusSymbols.thinking }
        return StatusSymbols.symbol(for: activity, attention: attention)
    }
    private var modelHelp: String? {
        guard let raw = activity.modelName else { return nil }
        return [raw, effortLabel.map { L10n.text("model.effort_help", $0) }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            rowContent(measuring: false)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered && enabled ? PacerPalette.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .background {
            rowContent(measuring: true).fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TaskRowIdealWidth.self, value: geometry.size.width)
                })
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(enabled ? [name, openHelp, modelHelp].compactMap { $0 }.joined(separator: "\n") : L10n.text("activity.no_link"))
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let state = [unread ? L10n.text("common.not_viewed") : nil, status, turnTime,
                     subagents > 0 ? L10n.text(subagents == 1 ? "activity.subagent_running" : "activity.subagents_running", subagents) : nil]
        let model = [modelLabel, effortLabel.map { L10n.text("model.effort_help", $0) }].compactMap { $0 }.joined(separator: " ")
        return activity.provider.displayName + ", " + L10n.text("activity.row_accessibility", name,
            state.compactMap { $0 }.joined(separator: ", "), sourceName ?? L10n.text("common.local")) + ", " + model + ", " + performanceText
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
                    Text(String(subagents)).monospacedDigit()
                }
                .foregroundStyle(PacerPalette.secondary).fixedSize()
                .help(L10n.text(subagents == 1 ? "activity.subagent_running" : "activity.subagents_running", subagents))
            }
            if let source = sourceName {
                HStack(spacing: 3) {
                    // Remote hosts get a server glyph; a local app is named as is.
                    if activity.sourceHostID != nil { Image(systemName: "server.rack").font(.system(size: 9, weight: .semibold)) }
                    Text(Self.middleTruncated(source, limit: 16))
                }
                .foregroundStyle(PacerPalette.secondary).lineLimit(1).fixedSize()
                .help(source)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var rateLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let rate {
                Text(String(format: "%.1f", rate.value)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rate.isFresh && !dimmed ? PacerPalette.primary : PacerPalette.secondary)
                Text(" t/s").font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
            } else {
                Text(L10n.text("performance.awaiting_usage")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PacerPalette.tertiary)
            }
            if let turnTime {
                Text(" · ").font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                Text(turnTime).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(phase == .running ? PacerPalette.primary.opacity(0.78) : PacerPalette.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).fixedSize()
        .help(performanceHelp)
    }

    private var modelLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let cost {
                Text(DeepSeekWallet.turnAmount(cost)).foregroundStyle(PacerPalette.primary.opacity(0.86)).padding(.trailing, 3)
                    .help(L10n.text("deepseek.turn_cost_row_help"))
            }
            Text(modelLabel)
            if let effortLabel { Text(effortLabel).opacity(0.62) }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(activity.provider.tint)
        .opacity(dimmed ? 0.7 : 1).lineLimit(1).fixedSize()
        .help(modelHelp ?? "")
    }

    static func shortened(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// Host names usually differ at the end (`gpu-03`), so keep both ends.
    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return String(text.prefix(half)) + "…" + String(text.suffix(limit - 1 - half))
    }
}

struct TaskRowIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
