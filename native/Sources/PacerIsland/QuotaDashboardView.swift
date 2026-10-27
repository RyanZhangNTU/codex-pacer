import SwiftUI
import PacerCore

struct QuotaDashboardSlot: Equatable, Identifiable, Sendable {
    let provider: AgentProvider
    var id: AgentProvider { provider }
}

enum QuotaDashboardLayout {
    /// Codex alone without a 5-hour window keeps the original bars in Classic.
    /// Split Ring draws a 7-day window itself, so there only nonstandard or
    /// unspecified limits keep them.
    static func usesLegacyCodexDisplay(providers: [AgentProvider], snapshot: QuotaSnapshot?, style: ExpandedQuotaStyle) -> Bool {
        guard Set(providers) == [.codex], let primary = snapshot?.buckets.first(where: { $0.id == "codex" }),
              !primary.windows.contains(where: { $0.durationMinutes == 300 }) else { return false }
        if style == .split, primary.windows.contains(where: { $0.durationMinutes == 10080 }) { return false }
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
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: model.enabledProviders, snapshot: model.providerQuota(.codex),
                                                       style: model.expandedQuotaStyle),
           let snapshot = model.providerQuota(.codex) {
            LegacyCodexQuotaView(model: model, snapshot: snapshot)
        } else if slots == [QuotaDashboardSlot(provider: .deepseek)] {
            DeepSeekSoloDashboard(model: model)
        } else if model.expandedQuotaStyle == .classic {
            ClassicQuotaDashboardView(model: model)
        } else if slots.count == 1, let provider = slots.first?.provider,
                  model.dashboardQuota(provider: provider, period: .weekly).availability != .unavailable {
            single(provider)
        } else {
            rings
        }
    }

    /// One service: the ring on the left, and beside it what the ring has no
    /// room for. The header above already names the provider.
    private func single(_ provider: AgentProvider) -> some View {
        let weekly = model.dashboardQuota(provider: provider, period: .weekly)
        let fiveHour = model.dashboardQuota(provider: provider, period: .fiveHour)
        let ring = QuotaDashboardRingView(quota: weekly, fiveHourQuota: fiveHour, providerHelp: providerHelp(provider),
                                          now: model.now, showsCaption: false)
        return VStack(spacing: 6) {
            HStack(spacing: 20) {
                ring
                QuotaDashboardDetailsView(quota: weekly, fiveHourQuota: ring.showsSplitRing ? fiveHour : nil, now: model.now)
            }
            .padding(.horizontal, IslandMetrics.rowInset)
            QuotaProviderStatusView(model: model, provider: provider)
        }.padding(.bottom, 4)
    }

    private var rings: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(slots) { slot in
                if slot.provider == .deepseek { DeepSeekDialCell(model: model, size: 104) } else {
                VStack(spacing: 6) {
                    QuotaDashboardRingView(quota: model.dashboardQuota(provider: slot.provider, period: .weekly),
                        fiveHourQuota: model.dashboardQuota(provider: slot.provider, period: .fiveHour),
                        providerHelp: providerHelp(slot.provider), now: model.now)
                    QuotaProviderStatusView(model: model, provider: slot.provider)
                }.frame(maxWidth: .infinity, alignment: .top)
                }
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
/// A weekly-only gauge opens at the bottom, so even a full arc keeps two ends
/// and room for its label.
struct QuotaRingGeometry {
    let startDegrees: Double
    let sweepDegrees: Double
    static let gauge = Self(startDegrees: 125, sweepDegrees: 290)
    static let fiveHour = Self(startDegrees: 204, sweepDegrees: 132)
    static let weekly = Self(startDegrees: 348, sweepDegrees: 204)

    func angle(at fraction: Double) -> Double { startDegrees + sweepDegrees * fraction }
}

struct QuotaRingReading {
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
    /// Either period's label and value turn amber together; only the 5h arc does.
    var labelColor: Color { pressing ? PacerPalette.attention : PacerPalette.tertiary }
    var valueColor: Color { fraction == nil ? PacerPalette.tertiary : (pressing ? PacerPalette.attention : PacerPalette.primary) }
    /// Pace and forecast, like the verdict, need fresh quota against the live clock.
    var paceText: String {
        guard quota.availability == .available, let pace = quota.window?.pacePercent(at: now) else { return "—" }
        return "\(Int(pace.rounded()))%"
    }
    var projection: QuotaProjection? { quota.availability == .available ? quota.window?.projection(at: now) : nil }
    var projectionWarns: Bool { if case .runsOut = projection { return true } else { return false } }
    func projectionText(inline: Bool) -> String? {
        switch projection {
        case nil: return nil
        case .tooEarly: return L10n.text("dashboard.projection_early")
        case .remainingAtReset(let left):
            return L10n.text(inline ? "dashboard.projection_left_inline" : "dashboard.projection_left", "\(Int(left.rounded()))%")
        case .runsOut(let seconds):
            guard seconds > 0 else { return L10n.text("dashboard.projection_used_up") }
            return L10n.text(inline ? "dashboard.projection_out_inline" : "dashboard.projection_out", CompactDuration.text(seconds))
        }
    }
    var resetMoment: String? { quota.window?.resetsAt.map { L10n.moment($0, relativeTo: now) } }
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
    /// Beside the single-service details the header already names the provider.
    var showsCaption = true
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
                    QuotaRingGauge(reading: weekly, geometry: .gauge)
                    QuotaRingValue(reading: weekly, size: 24, showsPeriod: false).frame(maxWidth: 76).offset(y: -4)
                    // The period sits in the opening, level with the arc's ends.
                    Text(quota.period.rawValue).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(weekly.pressing ? PacerPalette.attention : PacerPalette.secondary)
                        .position(x: Self.diameter / 2, y: Self.diameter * 0.91)
                        .opacity(weekly.stale ? 0.55 : 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            if showsCaption {
                HStack(spacing: 5) {
                    Text(quota.provider.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                    if !showsSplitRing, let verdict = weekly.verdict { QuotaVerdictChip(verdict: verdict) }
                    if weekly.stale || (showsSplitRing && fiveHourQuota?.availability == .stale) {
                        Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PacerPalette.attention)
                            .accessibilityLabel(L10n.text("common.not_updated"))
                    }
                }.frame(height: 15).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: showsCaption ? .infinity : nil)
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
                    Text(reading.quota.period.rawValue).font(.system(size: 9, weight: .medium)).foregroundStyle(reading.labelColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(reading.valueText).font(.system(size: size, weight: .semibold, design: .rounded))
                        .foregroundStyle(reading.valueColor)
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

/// Pace, reset moment and forecast beside a single service's ring. With 5h the
/// two groups face the upper and lower arcs; a weekly-only account gets rows.
private struct QuotaDashboardDetailsView: View {
    let quota: QuotaDashboardQuota
    let fiveHourQuota: QuotaDashboardQuota?
    let now: Date

    var body: some View {
        let weekly = QuotaRingReading(quota: quota, now: now)
        Group {
            if let fiveHourQuota {
                VStack(alignment: .leading, spacing: 9) {
                    QuotaPeriodDetailView(reading: QuotaRingReading(quota: fiveHourQuota, now: now))
                    Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                    QuotaPeriodDetailView(reading: weekly)
                }
            } else {
                VStack(spacing: 0) {
                    row(L10n.text("dashboard.pace")) {
                        if weekly.stale { QuotaFreshnessMark() } else if let verdict = weekly.verdict { QuotaVerdictChip(verdict: verdict) }
                        QuotaPaceValue(reading: weekly, showsLabel: false)
                    }
                    Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                    row(L10n.text("dashboard.reset")) {
                        Text(weekly.resetMoment ?? "—").font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.primary)
                    }
                    Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                    row(L10n.text("dashboard.projection")) {
                        Text(weekly.projectionText(inline: false) ?? "—").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(weekly.projectionWarns ? PacerPalette.attention :
                                (weekly.projection == nil || weekly.projection == .tooEarly ? PacerPalette.tertiary : PacerPalette.primary))
                    }
                }
                .help(weekly.detailsHelp)
                .accessibilityElement(children: .combine)
            }
        }
        .monospacedDigit().lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 11)).foregroundStyle(PacerPalette.secondary)
            Spacer(minLength: 6)
            value()
        }.frame(height: 26)
    }
}

private struct QuotaPeriodDetailView: View {
    let reading: QuotaRingReading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(reading.quota.period.rawValue).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(reading.pressing ? PacerPalette.attention : PacerPalette.secondary)
                if reading.stale { QuotaFreshnessMark() } else if let verdict = reading.verdict { QuotaVerdictChip(verdict: verdict) }
                Spacer(minLength: 6)
                QuotaPaceValue(reading: reading, showsLabel: true)
            }.frame(height: 16)
            HStack(spacing: 6) {
                Text(reading.resetMoment.map { L10n.text("dashboard.reset_at", $0) } ?? L10n.text("quota.reset_unknown"))
                Spacer(minLength: 6)
                if let projection = reading.projectionText(inline: true) {
                    Text(projection).foregroundStyle(reading.projectionWarns ? PacerPalette.attention : PacerPalette.tertiary)
                }
            }
            .font(.system(size: 10)).foregroundStyle(PacerPalette.tertiary)
        }
        .help(reading.detailsHelp)
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaPaceValue: View {
    let reading: QuotaRingReading
    let showsLabel: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if showsLabel { Text(L10n.text("dashboard.pace")).font(.system(size: 10)).foregroundStyle(PacerPalette.secondary) }
            Text(reading.paceText).font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(reading.verdict == .fast ? PacerPalette.attention : PacerPalette.primary)
        }
    }
}

private struct QuotaFreshnessMark: View {
    var body: some View {
        Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(PacerPalette.attention)
            .accessibilityLabel(L10n.text("common.not_updated"))
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
struct QuotaLinkButton: View {
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
