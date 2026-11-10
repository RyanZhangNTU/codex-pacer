import SwiftUI
import PacerCore

typealias ClassicQuotaDashboardSlot = QuotaDashboardPresentation.Slot

enum ClassicQuotaDashboardLayout {
    /// Two providers share the weekly ring with 5h one line below each; one
    /// provider shows both periods as rings. There is no period switch.
    static func slots(providers: [AgentProvider]) -> [ClassicQuotaDashboardSlot] {
        QuotaDashboardPresentation.slots(providers: providers, style: .classic)
    }
}

struct ClassicQuotaDashboardView: View {
    @ObservedObject var model: IslandModel
    let providers: [AgentProvider]
    /// The rings the block's services and windows give, in the panel's order.
    let slots: [ClassicQuotaDashboardSlot]

    var body: some View { rings }

    private var rings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(slots) { slot in
                    if slot.provider == .deepseek { DeepSeekDialCell(model: model, size: 88) } else {
                    VStack(spacing: 6) {
                        ClassicQuotaDashboardRingView(quota: model.dashboardQuota(provider: slot.provider, period: slot.period),
                            title: slot.title, identifiesProvider: slot.identifiesProvider,
                            providerHelp: providerHelp(slot.provider, period: slot.period), now: model.now)
                        if slot.identifiesProvider {
                            // A service limited to one window names no other.
                            if model.panelOptions.periods(for: slot.provider) == .both {
                                ClassicQuotaOtherPeriodView(quota: model.dashboardQuota(provider: slot.provider,
                                    period: slot.period == .fiveHour ? .weekly : .fiveHour), now: model.now)
                            }
                            QuotaProviderStatusView(model: model, provider: slot.provider)
                        }
                    }.frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            if providers.count == 1, let provider = providers.first {
                QuotaProviderStatusView(model: model, provider: provider)
                    .frame(maxWidth: .infinity)
            }
        }.padding(.bottom, 4)
    }

    private func providerHelp(_ provider: AgentProvider, period: QuotaDashboardPeriod) -> String {
        var details = [model.providerSourceText(provider), model.providerFreshnessText(provider, period: period)]
        if provider == .claude, model.claudeQuotaSource == .oauthUsage {
            details.append(L10n.text("claude.quota.source_service_help"))
        }
        return details.compactMap { $0 }.joined(separator: "\n")
    }
}

struct ClassicQuotaDashboardRingView: View {
    let quota: QuotaDashboardQuota
    let title: String
    let identifiesProvider: Bool
    let providerHelp: String
    let now: Date
    private var stale: Bool { quota.availability == .stale }
    private var proOnly: Bool { quota.availability == .proOnly }
    private var known: Bool { quota.remainingQuotaPercent.map(\.isFinite) ?? false }

    private static let diameter: CGFloat = 88
    private static let stroke: CGFloat = 6
    /// Pace needs fresh quota; a stale value against the live clock would mislead.
    private var reading: QuotaDashboardPresentation.Reading { quota.at(now) }
    private var verdict: QuotaPaceVerdict? { reading.verdict }
    @Environment(\.quotaPaceTick) private var showsPaceTick

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if proOnly {
                    let platinum = Color(red: 0.86, green: 0.88, blue: 0.91)
                    Circle().stroke(platinum.opacity(0.3), lineWidth: 1)
                    Circle().stroke(platinum.opacity(0.12), lineWidth: 1).padding(10)
                    Text(L10n.text("dashboard.pro"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).tracking(2.5).foregroundStyle(platinum)
                } else if quota.availability == .unavailable {
                    // Not connected: a quiet outline and the provider's mark, not an empty gauge.
                    Circle().stroke(PacerPalette.track, lineWidth: 1.5)
                    Image(systemName: quota.provider.glyph).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(PacerPalette.tertiary)
                } else {
                    ring(percent: quota.remainingQuotaPercent, lineWidth: Self.stroke, color: quota.provider.tint)
                    if showsPaceTick, let time = quota.remainingTimePercent.flatMap({ $0.isFinite ? min(100, max(0, $0)) : nil }) {
                        paceTick(at: time / 100)
                    }
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(reading.valueText)
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(known ? PacerPalette.primary : PacerPalette.tertiary)
                            if known {
                                Text("%").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(PacerPalette.secondary)
                            }
                        }.monospacedDigit()
                        if quota.window?.resetsAt != nil {
                            Text(countdown).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(PacerPalette.tertiary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: 66)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .opacity(stale ? 0.55 : 1)
            HStack(spacing: 5) {
                if identifiesProvider { Circle().fill(quota.provider.tint).frame(width: 6, height: 6) }
                Text(title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(identifiesProvider ? PacerPalette.primary : PacerPalette.secondary)
                if identifiesProvider {
                    // Without a period switch, the ring names its own window.
                    Text(quota.period.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
                if let verdict { QuotaVerdictChip(verdict: verdict) }
                if stale {
                    Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PacerPalette.attention)
                        .accessibilityLabel(L10n.text("common.not_updated"))
                }
            }.frame(height: 15)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(detailsHelp)
    }

    private func ring(percent: Double?, lineWidth: CGFloat, color: Color) -> some View {
        let fraction = percent.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
        return ZStack {
            Circle().stroke(PacerPalette.track,
                style: StrokeStyle(lineWidth: lineWidth, dash: fraction == nil ? [2, 5] : []))
            if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: CGFloat(fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.accessibilityHidden(true)
    }

    /// Where the arc would end at an even pace: an arc past the tick is ahead
    /// of the clock, one short of it is spending faster than time passes.
    private func paceTick(at fraction: Double) -> some View {
        Capsule().fill(PacerPalette.tick)
            .overlay(Capsule().stroke(PacerPalette.tickEdge, lineWidth: 0.5))
            .frame(width: 2.5, height: Self.stroke + 6)
            .offset(y: -Self.diameter / 2)
            .rotationEffect(.degrees(fraction * 360))
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String { reading.classicAccessibilityLabel }
    private var detailsHelp: String { reading.classicHelp(providerHelp: providerHelp) }
    private var countdown: String { reading.countdown }

}

/// The period not shown in the ring stays one line away instead of behind
/// the 5h/7d switch; it turns amber when low or spending faster than time.
private struct ClassicQuotaOtherPeriodView: View {
    let quota: QuotaDashboardQuota
    let now: Date

    var body: some View {
        let reading = quota.at(now)
        if let text = reading.otherPeriodText {
            Text(text)
                .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
                .foregroundStyle(reading.pressing ? PacerPalette.attention : PacerPalette.tertiary)
                .accessibilityLabel([quota.provider.displayName, quota.period.accessibilityLabel,
                    reading.valueText + "%", quota.window == nil ? nil : reading.countdown].compactMap { $0 }.joined(separator: ", "))
        }
    }
}
