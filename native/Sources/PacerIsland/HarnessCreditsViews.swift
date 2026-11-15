import PacerCore
import SwiftUI

/// A credits module's dial as Core words it: the month's credits as the
/// ring, the refresh or a lapse above the figure, and extra credits as a
/// badge in the ring's gap, or "This month" when there are none. The split
/// style draws the 290° gauge, classic a full ring with the gap line inside.
struct CreditsDial: View {
    let dial: HarnessCreditsPresentation.Dial
    let tint: Color
    var geometry: QuotaRingGeometry = .gauge
    var size: CGFloat = 104
    var stale = false
    /// Island colors on the dark surface; system colors in Settings.
    var island = true

    private var primary: Color { island ? PacerPalette.primary : .primary }
    private var secondary: Color { island ? PacerPalette.secondary : .secondary }
    private var warning: Color { island ? PacerPalette.attention : MainPalette.attention }
    private var gapInside: Bool { geometry.sweepDegrees >= 360 }

    var body: some View {
        ZStack {
            // The island's track vanishes on a light page; Settings draws its own.
            if !island { QuotaRingArc(geometry: geometry).stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round)) }
            QuotaRingGauge(fraction: dial.fraction, tint: tint, stale: stale, geometry: geometry)
            VStack(spacing: size * 0.02) {
                if let top = dial.top {
                    Text(top).font(.system(size: max(9, size * 0.095), weight: .semibold))
                        .foregroundStyle(dial.topWarns ? warning : secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(dial.center).font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                    .foregroundStyle(primary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.35)
                if gapInside { gap }
            }
            .frame(width: size * 0.7)
            .opacity(stale ? 0.55 : 1)
            if !gapInside { gap.offset(y: size * 0.41) }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dial.accessibilityLabel)
    }

    /// Extra credits as a capsule, or the month's label, in the ring's gap.
    @ViewBuilder private var gap: some View {
        if let badge = dial.badge {
            let (fill, ink): (Color, Color) = switch dial.badgeTone {
            case .normal: (tint.opacity(0.22), tint)
            case .warning: (warning.opacity(0.22), warning)
            case .solid: (tint, Color.black.opacity(0.8))
            }
            Text(badge).font(.system(size: max(9, size * 0.09), weight: .semibold)).monospacedDigit()
                .foregroundStyle(ink).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(fill, in: Capsule())
        } else if let label = dial.gapLabel {
            Text(label).font(.system(size: max(9, size * 0.09), weight: .medium)).foregroundStyle(secondary).lineLimit(1)
        }
    }
}

/// The lines beside a dial: a label, then the value and its detail, the
/// detail in orange when credits are about to lapse; the plan sits on the first.
struct CreditsLines: View {
    let presentation: HarnessCreditsPresentation
    let tint: Color
    var island = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { index, line in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(line.label).font(.system(size: 11)).foregroundStyle(island ? PacerPalette.secondary : .secondary)
                        if index == 0, let plan = presentation.plan {
                            Text(plan).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(tint.opacity(0.18), in: Capsule())
                        }
                    }
                    (Text(line.value).fontWeight(.semibold).foregroundColor(island ? PacerPalette.primary : .primary)
                        + Text(line.detail.map { " · " + $0 } ?? "")
                            .foregroundColor(line.warns ? (island ? PacerPalette.attention : MainPalette.attention)
                                                        : (island ? PacerPalette.secondary : .secondary)))
                        .font(.system(size: 12.5)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The bill's groups by how they behave: a title, then each group with a
/// chip when it lapses soon, its amount and its date.
struct CreditsSections: View {
    let sections: [HarnessCreditsPresentation.Section]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row.name).font(.system(size: 12.5))
                            if let chip = row.chip {
                                Text(chip).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(MainPalette.attention)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(MainPalette.attention.opacity(0.14), in: Capsule())
                            }
                            Spacer(minLength: 8)
                            Text(row.amount).font(.system(size: 12.5)).monospacedDigit()
                            if let date = row.date {
                                Text(date).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(minWidth: 80, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}
