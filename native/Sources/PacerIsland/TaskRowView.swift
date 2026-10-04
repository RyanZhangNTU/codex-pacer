import SwiftUI
import PacerCore

struct TaskRowView: View {
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
    private var detail: String { phase == .completed ? L10n.text("activity.turn_finished") : activity.detail(at: now) }
    private var color: Color {
        switch phase {
        case .waitingForInput, .interrupted: return Color(red: 0.91, green: 0.75, blue: 0.48)
        case .running: return accent
        case .completed: return Color(red: 0.56, green: 0.84, blue: 0.79)
        default: return .secondary
        }
    }
    private var symbol: String {
        switch phase {
        case .running: return activity.stage == .tool ? "terminal.fill" : "curlybraces"
        case .waitingForInput: return "bubble.left.and.text.bubble.right.fill"
        case .interrupted: return "pause.fill"
        case .completed: return "checkmark"
        default: return "circle.lefthalf.filled"
        }
    }

    var body: some View {
        Button(action: action) {
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
                }
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(hovered && enabled ? 0.8 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovered && enabled ? 0.055 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(enabled ? [L10n.text("common.open_chat"), activity.modelName].compactMap { $0 }.joined(separator: " · ") : L10n.text("activity.no_link"))
        .accessibilityLabel(L10n.text("activity.row_accessibility", name, detail, activity.sourceHost ?? L10n.text("common.local")))
    }
}
