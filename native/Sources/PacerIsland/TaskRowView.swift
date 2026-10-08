import SwiftUI
import PacerCore

struct TaskRowView: View {
    var attention: PendingAttentionRequest.Kind? = nil
    let activity: SessionActivity
    let name: String
    let now: Date
    let enabled: Bool
    let unread: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var phase: ActivityPhase { activity.observedPhase(at: now) }
    private var detail: String {
        if let attention {
            let prompt = L10n.text(attention == .approval ? "attention.approval" : "attention.input")
            return phase == .running ? prompt + " · " + activity.detail(at: now) : prompt
        }
        return phase == .completed ? L10n.text("activity.turn_finished") : activity.detail(at: now)
    }
    private var performanceText: String {
        let speed = activity.responsePerformance.map { String(format: "%.1f t/s", $0.tokensPerSecond) }
            ?? activity.outputEstimate(at: now).map { String(format: "~%.1f t/s", $0.value) }
            ?? L10n.text("performance.awaiting_usage")
        let latency = activity.firstTokenLatency.map { String(format: "%.2f s", $0) } ?? "—"
        return speed + "  ·  " + L10n.text("performance.first_output", latency)
    }
    private var performanceHelp: String {
        let latency = L10n.text("performance.latency_help")
        guard let sample = activity.responsePerformance else { return L10n.text("performance.awaiting_usage_help") + "\n" + latency }
        return L10n.text("performance.response_help", sample.outputTokens, sample.duration) + "\n" + latency
    }
    private var color: Color {
        if attention != nil { return .orange }
        if activity.turnFailed { return .red }
        switch phase {
        case .waitingForInput, .interrupted: return Color(red: 0.91, green: 0.75, blue: 0.48)
        case .running: return accent
        case .completed: return Color(red: 0.56, green: 0.84, blue: 0.79)
        default: return .secondary
        }
    }
    private var symbol: String {
        StatusSymbols.symbol(for: activity, attention: attention)
    }

    var body: some View {
        Button(action: action) {
            rowContent
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovered && enabled ? 0.055 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
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
        .help(enabled ? [L10n.text("common.open_chat"), activity.modelName].compactMap { $0 }.joined(separator: " · ") : L10n.text("activity.no_link"))
        .accessibilityLabel(L10n.text("activity.row_accessibility", name, detail, activity.sourceHost ?? L10n.text("common.local")) + ", " + performanceText)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                .frame(width: 24, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    if unread { Circle().fill(color).frame(width: 5, height: 5).accessibilityLabel(L10n.text("common.not_viewed")) }
                }
                HStack(spacing: 8) {
                    Text(detail).foregroundStyle(color).lineLimit(1)
                    Spacer(minLength: 4)
                    if let host = activity.sourceHost {
                        Text(host).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.font(.system(size: 12))
                Text(performanceText).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1).help(performanceHelp)
            }
            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovered && enabled ? 0.8 : 0))
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
    }
}

struct TaskRowIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
