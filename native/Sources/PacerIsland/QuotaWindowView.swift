import SwiftUI
import PacerCore

struct QuotaWindowView: View {
    let window: QuotaWindow
    let now: Date
    let allowPace: Bool
    let accent: Color
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))%").font(.system(size: 24, weight: .medium)).monospacedDigit()
                    Text("剩余").font(.system(size: 11)).foregroundStyle(secondary)
                } else { Text("—").font(.system(size: 24)).foregroundStyle(secondary) }
            }
            VStack(spacing: 5) {
                track(percent: window.remainingPercent, color: accent, height: 6)
                track(percent: window.elapsedTimePercent(at: now), color: .white.opacity(0.4), height: 3)
            }.help("上方：剩余额度；下方：已过时间")
            HStack(spacing: 8) {
                Text(window.elapsedTimePercent(at: now).map { "已过 \(Int($0))%" } ?? "时间 —")
                Text(countdown).help(resetDate)
                Spacer(minLength: 4)
                if allowPace, let pace = window.pacePercent(at: now) {
                    Text("配速 \(Int(pace.rounded()))%").foregroundStyle(pace < 85 ? Color.orange : pace > 115 ? accent : secondary)
                } else { Text("配速 —") }
            }.font(.system(size: 11)).foregroundStyle(secondary).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private func track(percent: Double?, color: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.08)).overlay(alignment: .leading) {
                if let percent { Capsule().fill(color).frame(width: geometry.size.width * min(100, max(0, percent)) / 100) }
            }
        }.frame(height: height)
    }
    private var countdown: String {
        guard let seconds = window.remainingSeconds(at: now) else { return "剩余 —" }
        if seconds <= 0 { return "等待更新" }
        if seconds < 60 { return "不足 1 分钟" }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return "剩余 \(days)天\(hours)小时" }
        if hours > 0 { return "剩余 \(hours)小时\(minutes)分" }
        return "剩余 \(minutes)分"
    }
    private var resetDate: String {
        window.resetsAt.map { "重置：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "重置时间未知"
    }
}
