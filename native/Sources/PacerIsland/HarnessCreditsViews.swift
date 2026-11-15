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
                        .frame(maxWidth: Self.topWidth(size))
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

    /// The widest the line above the figure may run and stay inside the ring:
    /// the chord at its height, inside the 6-point stroke with 3 points clear,
    /// and never more than 72% of the dial, as on Windows.
    static func topWidth(_ size: CGFloat) -> CGFloat {
        let inner = size / 2 - 6, rise = size / 2 - 0.23 * size
        return min(0.72 * size, 2 * (max(0, inner * inner - rise * rise)).squareRoot())
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

/// The lines beside a dial, laid out like a period of Codex's single view:
/// the label at the left (the plan beside the first) and the value at the
/// right, a caption under them in orange when credits are about to lapse,
/// and a hairline between lines. The column stays narrow enough that values
/// sit near their labels on a wide card.
struct CreditsLines: View {
    let presentation: HarnessCreditsPresentation
    let tint: Color
    var island = true
    static let maxWidth: CGFloat = 340

    private var secondary: Color { island ? PacerPalette.secondary : Color(nsColor: .secondaryLabelColor) }
    private var tertiary: Color { island ? PacerPalette.tertiary : Color(nsColor: .tertiaryLabelColor) }
    private var warning: Color { island ? PacerPalette.attention : MainPalette.attention }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { index, line in
                if index > 0 {
                    Rectangle().fill(island ? PacerPalette.hairline : MainPalette.separator).frame(height: 1).padding(.vertical, 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.label).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                        if index == 0, let plan = presentation.plan {
                            Text(plan).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(tint.opacity(0.18), in: Capsule())
                        }
                        Spacer(minLength: 8)
                        Text(line.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(island ? PacerPalette.primary : .primary).lineLimit(1)
                    }
                    if let detail = line.detail {
                        Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(line.warns ? warning : tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.label + " " + line.value + (line.detail.map { ", " + $0 } ?? ""))
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
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
