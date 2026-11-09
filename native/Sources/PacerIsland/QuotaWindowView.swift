import SwiftUI
import PacerCore

struct QuotaWindowView: View {
    let reading: QuotaDashboardPresentation.LegacyWindow
    let accent: Color
    let secondary: Color
    var referenceColor: Color = PacerPalette.tick
    /// Read after the window's own description, such as where the quota came from.
    var note: String?

    init(window: QuotaWindow, now: Date, allowPace: Bool, accent: Color, secondary: Color, referenceColor: Color = PacerPalette.tick) {
        self.init(reading: .init(window: window, allowPace: allowPace, now: now), accent: accent,
            secondary: secondary, referenceColor: referenceColor)
    }
    init(reading: QuotaDashboardPresentation.LegacyWindow, accent: Color, secondary: Color, referenceColor: Color = PacerPalette.tick,
         note: String? = nil) {
        self.reading = reading; self.accent = accent; self.secondary = secondary; self.referenceColor = referenceColor
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
                Spacer()
                if let remaining = reading.remainingPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(reading.valueText).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text("%").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(secondary)
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("quota.remaining", Int(remaining.rounded())))
                } else { Text("—").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(secondary) }
            }
            quotaTrack
            HStack(spacing: 8) {
                Text(reading.countdown)
                Spacer(minLength: 4)
                Text(reading.paceText).foregroundStyle(reading.pacePercent.map { $0 < 85 ? Color.orange : $0 > 115 ? accent : secondary } ?? secondary)
            }.font(.system(size: 11)).foregroundStyle(secondary).monospacedDigit()
        }.accessibilityElement(children: .combine)
        .accessibilityHint([reading.resetDate, L10n.text("quota.track_help"), note].compactMap { $0 }.joined(separator: " "))
    }
    private var quotaTrack: some View {
        GeometryReader { geometry in
            Capsule().fill(referenceColor.opacity(0.08)).overlay(alignment: .leading) {
                if let percent = reading.remainingPercent {
                    Capsule().fill(accent).frame(width: geometry.size.width * percent / 100)
                }
            }.overlay(alignment: .leading) {
                if let expected = reading.remainingTimePercent {
                    Capsule().fill(referenceColor.opacity(0.65)).frame(width: 2, height: 11)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * expected / 100 - 1)))
                }
            }
        }.frame(height: 6).padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}
