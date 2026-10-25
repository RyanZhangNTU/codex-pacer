import SwiftUI
import PacerCore

struct QuotaDashboardSlot: Equatable, Identifiable, Sendable {
    let provider: AgentProvider
    var id: AgentProvider { provider }
}

enum QuotaDashboardLayout {
    static func usesLegacyCodexDisplay(providers: [AgentProvider], snapshot: QuotaSnapshot?) -> Bool {
        guard Set(providers) == [.codex], let primary = snapshot?.buckets.first(where: { $0.id == "codex" }),
              !primary.windows.contains(where: { $0.durationMinutes == 300 }) else { return false }
        return primary.windows.contains {
            $0.remainingPercent != nil || ($0.durationMinutes.map { $0 > 0 } ?? false) || $0.resetsAt != nil
        }
    }

    /// Each provider keeps one gauge, whether one or both modules are enabled.
    static func slots(providers: [AgentProvider]) -> [QuotaDashboardSlot] {
        let enabled = Set(providers)
        return AgentProvider.allCases.filter { enabled.contains($0) }.map { QuotaDashboardSlot(provider: $0) }
    }
}

extension QuotaDashboardPeriod {
    var accessibilityLabel: String {
        self == .fiveHour ? L10n.text("quota.hours", 5) : L10n.text("quota.days", 7)
    }
}

struct QuotaDashboardView: View {
    @ObservedObject var model: IslandModel
    private var slots: [QuotaDashboardSlot] {
        QuotaDashboardLayout.slots(providers: model.enabledProviders)
    }

    var body: some View {
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: model.enabledProviders, snapshot: model.providerQuota(.codex)),
           let snapshot = model.providerQuota(.codex) {
            LegacyCodexQuotaView(model: model, snapshot: snapshot)
        } else if model.expandedQuotaStyle == .classic {
            ClassicQuotaDashboardView(model: model)
        } else {
            rings
        }
    }

    private var rings: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(slots) { slot in
                VStack(spacing: 6) {
                    QuotaDashboardRingView(quota: model.dashboardQuota(provider: slot.provider, period: .weekly),
                        fiveHourQuota: model.dashboardQuota(provider: slot.provider, period: .fiveHour),
                        providerHelp: providerHelp(slot.provider), now: model.now)
                    QuotaProviderStatusView(model: model, provider: slot.provider)
                }.frame(maxWidth: .infinity, alignment: .top)
            }
        }.padding(.bottom, 4)
    }

    private func providerHelp(_ provider: AgentProvider) -> String {
        var details = [model.providerSourceText(provider)]
        if provider == .claude, model.claudeQuotaSource == .oauthUsage {
            details.append(L10n.text("claude.quota.source_service_help"))
        }
        return details.compactMap { $0 }.joined(separator: "\n")
    }
}

private struct LegacyCodexQuotaView: View {
    @ObservedObject var model: IslandModel
    let snapshot: QuotaSnapshot
    private var fresh: Bool { !model.providerQuotaIsStale(.codex) && model.providerQuotaError(.codex) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !fresh {
                Label(L10n.text("common.not_updated"), systemImage: StatusSymbols.freshness)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.attention)
                    .help([model.providerSourceText(.codex), model.providerFreshnessText(.codex)].compactMap { $0 }.joined(separator: "\n"))
            }
            ForEach(snapshot.buckets) { bucket in
                if !bucket.windows.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        if snapshot.buckets.count > 1 {
                            Text(bucket.name ?? bucket.id).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                        }
                        ForEach(bucket.windows) { window in
                            QuotaWindowView(window: window, now: model.now, allowPace: fresh,
                                accent: fresh ? AgentProvider.codex.tint : PacerPalette.secondary, secondary: PacerPalette.secondary)
                        }
                    }
                }
            }
            QuotaProviderStatusView(model: model, provider: .codex).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.bottom, 4)
        .help([model.providerSourceText(.codex), model.providerFreshnessText(.codex)].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// Both arcs advance clockwise, each against its own quota and reset clock.
/// The breaks sit above the center, leaving more of the circle for the week.
struct QuotaRingGeometry {
    let startDegrees: Double
    let sweepDegrees: Double
    static let full = Self(startDegrees: -90, sweepDegrees: 360)
    static let fiveHour = Self(startDegrees: 204, sweepDegrees: 132)
    static let weekly = Self(startDegrees: 348, sweepDegrees: 204)

    func angle(at fraction: Double) -> Double { startDegrees + sweepDegrees * fraction }
}

private struct QuotaRingReading {
    let quota: QuotaDashboardQuota
    let now: Date
    var fraction: Double? { normalized(quota.remainingQuotaPercent) }
    var timeFraction: Double? { normalized(quota.remainingTimePercent) }
    var stale: Bool { quota.availability == .stale }
    var verdict: QuotaPaceVerdict? {
        guard quota.availability == .available, let pace = quota.window?.pacePercent(at: now) else { return nil }
        return QuotaPaceVerdict(pace: pace)
    }
    var pressing: Bool {
        quota.availability == .available && (fraction.map { $0 <= 0.15 } == true || verdict == .fast)
    }
    var tint: Color { quota.period == .fiveHour && pressing ? PacerPalette.attention : quota.provider.tint }
    var valueText: String { percentText(quota.remainingQuotaPercent).replacingOccurrences(of: "%", with: "") }
    var countdown: String {
        guard let seconds = quota.window?.remainingSeconds(at: now) else { return "—" }
        return seconds <= 0 ? L10n.text("dashboard.countdown_waiting") : CompactDuration.text(seconds)
    }
    var resetDate: String {
        quota.window?.resetsAt.map { L10n.text("quota.reset_date", L10n.date($0)) } ?? L10n.text("quota.reset_unknown")
    }
    var detailsHelp: String {
        var details = [L10n.text("dashboard.rings_help")]
        if let name = quota.bucketName { details.append(name) }
        if quota.availability == .missingPeriod {
            details.append(L10n.text("dashboard.period_unavailable", quota.period.accessibilityLabel))
        }
        details.append(L10n.text("dashboard.time_remaining", percentText(quota.remainingTimePercent)))
        details.append(resetDate)
        if let verdict { details.append(verdict.label) }
        details.append(quota.freshnessText)
        return details.joined(separator: "\n")
    }
    var accessibilityLabel: String {
        let provider = quota.bucketName.map { quota.provider.displayName + " " + $0 } ?? quota.provider.displayName
        return L10n.text("dashboard.rings_accessibility", provider, quota.period.accessibilityLabel,
            fraction == nil ? L10n.text("common.unknown") : percentText(quota.remainingQuotaPercent),
            timeFraction == nil ? L10n.text("common.unknown") : percentText(quota.remainingTimePercent),
            [resetDate, verdict?.label, quota.freshnessText].compactMap { $0 }.joined(separator: ". "))
    }
    private func normalized(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
    }
    private func percentText(_ value: Double?) -> String {
        guard let fraction = normalized(value) else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

struct QuotaDashboardRingView: View {
    let quota: QuotaDashboardQuota
    var fiveHourQuota: QuotaDashboardQuota? = nil
    let providerHelp: String
    let now: Date
    private static let diameter: CGFloat = 104
    private var weekly: QuotaRingReading { QuotaRingReading(quota: quota, now: now) }
    /// A reported window establishes the split even when its usage is unknown
    /// or stale. A model-scoped limit or an unread account cannot invent 5h.
    var showsSplitRing: Bool {
        fiveHourQuota?.provider == quota.provider && fiveHourQuota?.period == .fiveHour && fiveHourQuota?.window != nil
    }
    private var detailsHelp: String {
        var readings = [weekly]
        if showsSplitRing, let fiveHourQuota { readings.insert(QuotaRingReading(quota: fiveHourQuota, now: now), at: 0) }
        return (readings.map { $0.quota.period.rawValue + "\n" + $0.detailsHelp } + [providerHelp]).joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if showsSplitRing, let fiveHourQuota {
                    let short = QuotaRingReading(quota: fiveHourQuota, now: now)
                    QuotaRingGauge(reading: short, geometry: .fiveHour)
                    QuotaRingGauge(reading: weekly, geometry: .weekly)
                    VStack(spacing: 7) {
                        QuotaRingValue(reading: short, size: 18, showsPeriod: true)
                        QuotaRingValue(reading: weekly, size: 22, showsPeriod: true)
                    }.frame(maxWidth: 76)
                } else if quota.availability == .unavailable {
                    Circle().stroke(PacerPalette.track, lineWidth: 1.5)
                    Image(systemName: quota.provider.glyph).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(PacerPalette.tertiary)
                        .accessibilityLabel(weekly.accessibilityLabel)
                } else {
                    QuotaRingGauge(reading: weekly, geometry: .full)
                    QuotaRingValue(reading: weekly, size: 24, showsPeriod: false).frame(maxWidth: 76)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            HStack(spacing: 5) {
                Text(quota.provider.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                if !showsSplitRing {
                    Text(quota.period.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                    if let verdict = weekly.verdict { QuotaVerdictChip(verdict: verdict) }
                }
                if weekly.stale || (showsSplitRing && fiveHourQuota?.availability == .stale) {
                    Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PacerPalette.attention)
                        .accessibilityLabel(L10n.text("common.not_updated"))
                }
            }.frame(height: 15).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .help(detailsHelp)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(quota.provider.displayName)
    }
}

private struct QuotaRingArc: Shape {
    let geometry: QuotaRingGeometry
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                startAngle: .degrees(geometry.startDegrees), endAngle: .degrees(geometry.angle(at: 1)), clockwise: false)
        }
    }
}

private struct QuotaRingGauge: View {
    let reading: QuotaRingReading
    let geometry: QuotaRingGeometry
    private static let stroke: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                QuotaRingArc(geometry: geometry).stroke(PacerPalette.track,
                    style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round, dash: reading.fraction == nil ? [2, 5] : []))
                if let fraction = reading.fraction, fraction > 0 {
                    QuotaRingArc(geometry: geometry).trim(from: 0, to: CGFloat(fraction))
                        .stroke(reading.tint, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
                }
                if let time = reading.timeFraction {
                    Capsule().fill(Color.white)
                        .overlay(Capsule().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
                        .frame(width: 2.5, height: Self.stroke + 6)
                        .offset(y: -min(proxy.size.width, proxy.size.height) / 2)
                        .rotationEffect(.degrees(geometry.angle(at: time) + 90))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
        .opacity(reading.stale ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

private struct QuotaRingValue: View {
    let reading: QuotaRingReading
    let size: CGFloat
    let showsPeriod: Bool

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if showsPeriod {
                    Text(reading.quota.period.rawValue).font(.system(size: 9, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(reading.valueText).font(.system(size: size, weight: .semibold, design: .rounded))
                        .foregroundStyle(reading.fraction == nil ? PacerPalette.tertiary :
                            (reading.quota.period == .fiveHour && reading.pressing ? PacerPalette.attention : PacerPalette.primary))
                    if reading.fraction != nil {
                        Text("%").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(PacerPalette.secondary)
                    }
                }
            }.frame(height: size + 2).monospacedDigit()
            if reading.quota.window?.resetsAt != nil {
                Text(reading.countdown).font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(PacerPalette.tertiary).frame(height: 11)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .opacity(reading.stale ? 0.55 : 1)
        .help(reading.detailsHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityLabel)
        .accessibilityHint(reading.detailsHelp)
    }
}

struct QuotaProviderStatusView: View {
    @ObservedObject var model: IslandModel
    let provider: AgentProvider

    var body: some View {
        VStack(spacing: 6) {
            if let error = model.providerQuotaError(provider) {
                Text(error).font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                connectionActions
            } else if model.providerQuota(provider)?.windows.isEmpty != false {
                Text(model.providerRefreshing(provider) ? L10n.text("quota.loading") : L10n.text("dashboard.provider_unavailable", provider.displayName))
                    .font(.system(size: 11)).foregroundStyle(PacerPalette.secondary).fixedSize(horizontal: false, vertical: true)
                QuotaLinkButton(title: L10n.text("common.open_settings")) { model.openSettings(for: provider) }
            }
        }.multilineTextAlignment(.center)
    }

    private var connectionActions: some View {
        HStack(spacing: 6) {
            if provider == .claude, model.claudeConnectionNeeded {
                QuotaLinkButton(title: L10n.text(model.claudeConnectionActionTitleKey), prominent: true) { model.connectClaudeQuota() }
                    .help(L10n.text(model.claudeConnectionActionHelpKey)).disabled(model.providerRefreshing(provider))
            }
            QuotaLinkButton(title: L10n.text(model.providerRefreshing(provider) ? "common.retrying" : "common.retry")) {
                model.retryQuotaConnection(for: provider)
            }.disabled(model.providerRefreshing(provider))
            QuotaLinkButton(title: L10n.text("common.settings")) { model.openSettings(for: provider) }
        }
    }
}

/// Small capsule actions keep recovery visible without competing with the rings.
private struct QuotaLinkButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : PacerPalette.primary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(prominent ? PacerPalette.primary : (hovered ? PacerPalette.hover : PacerPalette.fill), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}
