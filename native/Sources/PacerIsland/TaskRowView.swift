import SwiftUI
import PacerCore

struct TaskRowView: View {
    let activity: SessionActivity
    let name: String
    let now: Date
    let enabled: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var phase: ActivityPhase { activity.observedPhase(at: now) }
    private var color: Color {
        switch phase {
        case .waitingForInput, .interrupted: return Color(red: 0.91, green: 0.75, blue: 0.48)
        case .running: return accent
        default: return .secondary
        }
    }
    private var symbol: String {
        switch phase {
        case .running: return activity.stage == .tool ? "terminal.fill" : "curlybraces"
        case .waitingForInput: return "bubble.left.and.text.bubble.right.fill"
        case .interrupted: return "pause.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.16), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(activity.detail(at: now)).foregroundStyle(color).lineLimit(1)
                        Spacer(minLength: 4)
                        Label(activity.sourceHost ?? "本机", systemImage: activity.sourceHost == nil ? "desktopcomputer" : "network")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }.font(.system(size: 10))
                }
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(hovered && enabled ? 0.8 : 0.3))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(hovered && enabled ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(hovered && enabled ? 0.14 : 0.055), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(enabled ? ["打开会话", activity.modelName].compactMap { $0 }.joined(separator: " · ") : "此来源没有可用的会话链接")
        .accessibilityLabel("\(name)，\(activity.detail(at: now))，\(activity.sourceHost ?? "本机")。打开会话")
    }
}
