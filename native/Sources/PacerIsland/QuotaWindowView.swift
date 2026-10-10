import SwiftUI
import PacerCore

struct QuotaWindowView: View {
    let window: QuotaWindow
    let now: Date
    let allowPace: Bool
    let accent: Color
    let secondary: Color
    var referenceColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 14, weight: .medium))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 28, weight: .medium)).monospacedDigit()
                        .accessibilityLabel(L10n.text("quota.remaining", Int(remaining.rounded())))
                } else { Text("—").font(.system(size: 28)).foregroundStyle(secondary) }
            }
            quotaTrack
            HStack(spacing: 8) {
                Text(countdown).help(resetDate)
                Spacer(minLength: 4)
                if allowPace, let pace = window.pacePercent(at: now) {
                    Text(L10n.text("quota.pace_value", Int(pace.rounded()))).foregroundStyle(pace < 85 ? Color.orange : pace > 115 ? accent : secondary)
                } else { Text(L10n.text("quota.pace_unknown")) }
            }.font(.system(size: 12)).foregroundStyle(secondary).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private var quotaTrack: some View {
        GeometryReader { geometry in
            Capsule().fill(referenceColor.opacity(0.09)).overlay(alignment: .leading) {
                if let percent = window.remainingPercent {
                    Capsule().fill(accent).frame(width: geometry.size.width * percent / 100)
                }
            }.overlay(alignment: .leading) {
                if allowPace, let expected = window.remainingTimePercent(at: now) {
                    Capsule().fill(referenceColor.opacity(0.65)).frame(width: 2, height: 11)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * expected / 100 - 1)))
                }
            }
        }.frame(height: 5).padding(.vertical, 3)
        .help(L10n.text("quota.track_help"))
        .accessibilityHidden(true)
    }
    private var countdown: String {
        guard let seconds = window.remainingSeconds(at: now) else { return L10n.text("quota.reset_unknown") }
        if seconds <= 0 { return L10n.text("quota.waiting_update") }
        if seconds < 60 { return L10n.text("quota.reset_soon") }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("quota.reset_days", days, hours) }
        if hours > 0 { return L10n.text("quota.reset_hours", hours, minutes) }
        return L10n.text("quota.reset_minutes", minutes)
    }
    private var resetDate: String {
        window.resetsAt.map { L10n.text("quota.reset_date", L10n.date($0)) } ?? L10n.text("quota.reset_unknown")
    }
}
