import SwiftUI
import PacerCore

struct QuotaWindowView: View {
    let window: QuotaWindow
    let now: Date
    let allowPace: Bool
    let accent: Color
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 14, weight: .medium))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 28, weight: .medium)).monospacedDigit()
                        .accessibilityLabel("剩余 \(Int(remaining.rounded()))%")
                } else { Text("—").font(.system(size: 28)).foregroundStyle(secondary) }
            }
            quotaTrack
            HStack(spacing: 8) {
                Text(countdown).help(resetDate)
                Spacer(minLength: 4)
                if allowPace, let pace = window.pacePercent(at: now) {
                    Text("配速 \(Int(pace.rounded()))%").foregroundStyle(pace < 85 ? Color.orange : pace > 115 ? accent : secondary)
                } else { Text("配速 —") }
            }.font(.system(size: 12)).foregroundStyle(secondary).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private var quotaTrack: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.09)).overlay(alignment: .leading) {
                if let percent = window.remainingPercent {
                    Capsule().fill(accent).frame(width: geometry.size.width * percent / 100)
                }
            }.overlay(alignment: .leading) {
                if allowPace, let expected = window.remainingTimePercent(at: now) {
                    Capsule().fill(.white.opacity(0.65)).frame(width: 2, height: 11)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * expected / 100 - 1)))
                }
            }
        }.frame(height: 5).padding(.vertical, 3)
        .help("实色为剩余额度，刻度为按时间均匀使用时应剩的额度")
        .accessibilityHidden(true)
    }
    private var countdown: String {
        guard let seconds = window.remainingSeconds(at: now) else { return "重置时间未知" }
        if seconds <= 0 { return "等待更新" }
        if seconds < 60 { return "1 分钟内重置" }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分后重置" }
        return "\(minutes)分钟后重置"
    }
    private var resetDate: String {
        window.resetsAt.map { "重置：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "重置时间未知"
    }
}
