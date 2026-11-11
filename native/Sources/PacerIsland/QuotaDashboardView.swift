import SwiftUI
import PacerCore

/// The white tick on Codex's and Claude's rings that marks an even pace.
private struct QuotaPaceTickKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var quotaPaceTick: Bool {
        get { self[QuotaPaceTickKey.self] }
        set { self[QuotaPaceTickKey.self] = newValue }
    }
}

struct QuotaDashboardSlot: Equatable, Identifiable, Sendable {
    let provider: AgentProvider
    var id: AgentProvider { provider }
}

enum QuotaDashboardLayout {
    /// Codex alone without a 5-hour window keeps the original bars in Classic.
    /// Split Ring draws a 7-day window itself, so there only nonstandard or
    /// unspecified limits keep them.
    static func usesLegacyCodexDisplay(providers: [AgentProvider], snapshot: QuotaSnapshot?, style: ExpandedQuotaStyle) -> Bool {
        QuotaDashboardPresentation.usesLegacyCodexDisplay(providers: providers, snapshot: snapshot, style: style)
    }

    /// Each provider keeps one gauge, whether one or both modules are enabled.
    static func slots(providers: [AgentProvider]) -> [QuotaDashboardSlot] {
        QuotaDashboardPresentation.slots(providers: providers, style: .split).map { QuotaDashboardSlot(provider: $0.provider) }
    }
}


struct QuotaDashboardView: View {
    @ObservedObject var model: IslandModel
    /// A quota block's services in the panel's order; Overview shows one per card.
    let providers: [AgentProvider]
    /// A lone DeepSeek day dial draws today's spend in its column.
    var spendBeside = false

    init(model: IslandModel, providers: [AgentProvider]) {
        self.model = model; self.providers = providers
    }

    init(model: IslandModel, section: ExpandedPanelPresentation.Section) {
        self.model = model; providers = section.providers; spendBeside = section.spendBeside
    }

    private var options: ExpandedPanelOptions { model.panelOptions }
    private var layout: QuotaDashboardPresentation.Layout {
        let options = options
        return QuotaDashboardPresentation.layout(providers: providers,
            snapshots: Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                model.providerQuota(provider).map { (provider, $0) }
            }), style: model.expandedQuotaStyle, now: model.now, preservingOrder: true, details: options.quotaDetails,
            periods: { options.periods(for: $0) })
    }

    var body: some View {
        let layout = layout
        Group {
            switch layout.kind {
            case .legacyCodex:
                if let snapshot = model.providerQuota(.codex) { LegacyCodexQuotaView(model: model, snapshot: snapshot) }
            case .deepseekSolo: DeepSeekSoloDashboard(model: model, spendBeside: spendBeside)
            case .classicRings:
                ClassicQuotaDashboardView(model: model, providers: providers, slots: layout.slots, showsDetails: layout.showsDetails == true)
            case .splitSingle:
                if let provider = layout.slots.first?.provider { single(provider) }
            case .splitRings: rings(layout.slots)
            }
        }
        .environment(\.quotaPaceTick, options.paceTick)
    }

    /// The window a service's ring draws, and the 5-hour quota when the ring splits.
    private func gauge(_ provider: AgentProvider) -> (main: QuotaDashboardQuota, fiveHour: QuotaDashboardQuota?) {
        let gauge = ExpandedPanelPresentation.gauge(provider: provider, snapshot: model.providerQuota(provider),
            periods: options.periods(for: provider))
        return (model.dashboardQuota(provider: provider, period: gauge.period),
                gauge.split ? model.dashboardQuota(provider: provider, period: .fiveHour) : nil)
    }

    /// One service: the ring on the left, and beside it what the ring has no
    /// room for. The header above already names the provider.
    private func single(_ provider: AgentProvider) -> some View {
        let (main, fiveHour) = gauge(provider)
        let ring = QuotaDashboardRingView(quota: main, fiveHourQuota: fiveHour, providerHelp: providerHelp(provider),
                                          now: model.now, showsCaption: false)
        return VStack(spacing: 6) {
            HStack(spacing: 20) {
                ring
                QuotaDashboardDetailsView(quota: main, fiveHourQuota: ring.showsSplitRing ? fiveHour : nil, now: model.now)
            }
            .padding(.horizontal, IslandMetrics.rowInset)
            QuotaProviderStatusView(model: model, provider: provider)
        }.padding(.bottom, 4)
    }

    private func rings(_ slots: [QuotaDashboardPresentation.Slot]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(slots) { slot in
                if slot.provider == .deepseek { DeepSeekDialCell(model: model, size: 104) } else {
                    let (main, fiveHour) = gauge(slot.provider)
                    VStack(spacing: 6) {
                        QuotaDashboardRingView(quota: main, fiveHourQuota: fiveHour, providerHelp: providerHelp(slot.provider), now: model.now)
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
    private var presentation: QuotaDashboardPresentation.Legacy {
        .init(snapshot: snapshot, failed: model.providerQuotaError(.codex) != nil,
            selectedWindowID: model.defaults.string(forKey: "quotaWindowID"), now: model.now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !presentation.fresh {
                Label(L10n.text("common.not_updated"), systemImage: StatusSymbols.freshness)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.attention)
                    .accessibilityHint(presentation.help)
            }
            ForEach(presentation.buckets, id: \.id) { bucket in
                    VStack(alignment: .leading, spacing: 14) {
                        if let title = bucket.title {
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                        }
                        ForEach(bucket.windows, id: \.id) { window in
                            QuotaWindowView(reading: window,
                                accent: presentation.fresh ? AgentProvider.codex.tint : PacerPalette.secondary, secondary: PacerPalette.secondary,
                                note: presentation.help)
                        }
                    }
            }
            QuotaProviderStatusView(model: model, provider: .codex).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.bottom, 4)
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
    private let reading: QuotaDashboardPresentation.Reading
    init(quota: QuotaDashboardQuota, now: Date) {
        self.quota = quota; self.now = now; self.reading = quota.at(now)
    }
    var fraction: Double? { reading.fraction }
    var timeFraction: Double? { reading.timeFraction }
    var stale: Bool { reading.availability == .stale }
    var verdict: QuotaPaceVerdict? { reading.verdict }
    var pressing: Bool { reading.pressing }
    var tint: Color { quota.period == .fiveHour && pressing ? PacerPalette.attention : quota.provider.tint }
    var labelColor: Color { pressing ? PacerPalette.attention : PacerPalette.tertiary }
    var valueColor: Color { fraction == nil ? PacerPalette.tertiary : pressing ? PacerPalette.attention : PacerPalette.primary }
    var paceText: String { reading.paceText }
    var projection: QuotaProjection? { reading.projection }
    var projectionWarns: Bool { reading.projectionWarns }
    func projectionText(inline: Bool) -> String? { inline ? reading.projectionInline : reading.projectionText }
    var resetMoment: String? { reading.resetMoment }
    var valueText: String { reading.valueText }
    var countdown: String { reading.countdown }
    var resetDate: String { reading.resetDate }
    var detailsHelp: String { reading.splitHelp }
    var accessibilityLabel: String { reading.accessibilityLabel }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(quota.provider.displayName)
        .accessibilityHint(detailsHelp)
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
    @Environment(\.quotaPaceTick) private var paceTick
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
                if paceTick, let time = reading.timeFraction {
                    Capsule().fill(PacerPalette.tick)
                        .overlay(Capsule().stroke(PacerPalette.tickEdge, lineWidth: 0.5))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityLabel)
        .accessibilityHint(reading.detailsHelp)
    }
}

/// Pace, reset moment and forecast beside a single service's ring. With 5h the
/// two groups face the upper and lower arcs; a weekly-only account gets rows.
struct QuotaDashboardDetailsView: View {
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
                .accessibilityElement(children: .combine)
                .accessibilityHint(weekly.detailsHelp)
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
        .accessibilityElement(children: .combine)
        .accessibilityHint(reading.detailsHelp)
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
        let status = QuotaConnectionPresentation(provider: provider, snapshot: model.providerQuota(provider),
            error: model.providerQuotaError(provider), refreshing: model.providerRefreshing(provider))
        VStack(spacing: 6) {
            if status.state == .error, let error = status.message {
                Text(error).font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                connectionActions
            } else if status.state != .hidden {
                Text(status.message ?? "")
                    .font(.system(size: 11)).foregroundStyle(PacerPalette.secondary).fixedSize(horizontal: false, vertical: true)
                QuotaLinkButton(title: L10n.text("common.open_settings")) { model.openSettings(for: provider) }
            }
        }.multilineTextAlignment(.center)
    }

    private var connectionActions: some View {
        HStack(spacing: 6) {
            if provider == .claude, model.claudeConnectionNeeded {
                QuotaLinkButton(title: L10n.text(model.claudeConnectionActionTitleKey), prominent: true) { model.connectClaudeQuota() }
                    .accessibilityHint(L10n.text(model.claudeConnectionActionHelpKey)).disabled(model.providerRefreshing(provider))
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
