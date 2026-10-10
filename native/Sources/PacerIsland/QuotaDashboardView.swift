import SwiftUI
import PacerCore

struct QuotaDashboardSlot: Equatable, Identifiable, Sendable {
    let provider: AgentProvider
    let period: QuotaDashboardPeriod
    let identifiesProvider: Bool
    var id: String { provider.rawValue + ":" + period.rawValue }
    var title: String { identifiesProvider ? provider.displayName : period.rawValue }
}

enum QuotaDashboardLayout {
    static func usesLegacyCodexDisplay(providers: [AgentProvider], snapshot: QuotaSnapshot?) -> Bool {
        guard Set(providers) == [.codex], let primary = snapshot?.buckets.first(where: { $0.id == "codex" }),
              !primary.windows.contains(where: { $0.durationMinutes == 300 }) else { return false }
        return primary.windows.contains {
            $0.remainingPercent != nil || ($0.durationMinutes.map { $0 > 0 } ?? false) || $0.resetsAt != nil
        }
    }

    static func slots(providers: [AgentProvider], selectedPeriod: QuotaDashboardPeriod) -> [QuotaDashboardSlot] {
        let enabled = Set(providers)
        let ordered = AgentProvider.allCases.filter { enabled.contains($0) }
        if let provider = ordered.first, ordered.count == 1 {
            return QuotaDashboardPeriod.allCases.map {
                QuotaDashboardSlot(provider: provider, period: $0, identifiesProvider: false)
            }
        }
        return ordered.map { QuotaDashboardSlot(provider: $0, period: selectedPeriod, identifiesProvider: true) }
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
        QuotaDashboardLayout.slots(providers: model.enabledProviders, selectedPeriod: model.dashboardPeriod)
    }

    var body: some View {
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: model.enabledProviders, snapshot: model.providerQuota(.codex)),
           let snapshot = model.providerQuota(.codex) {
            LegacyCodexQuotaView(model: model, snapshot: snapshot)
        } else {
            rings
        }
    }

    private var rings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.enabledProviders.count == 1, let provider = model.enabledProviders.first {
                Text(provider.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(provider.tint)
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(slots) { slot in
                    VStack(spacing: 10) {
                        QuotaDashboardRingView(quota: model.dashboardQuota(provider: slot.provider, period: slot.period),
                            title: slot.title, providerHelp: providerHelp(slot.provider, period: slot.period), now: model.now)
                        if slot.identifiesProvider {
                            QuotaProviderStatusView(model: model, provider: slot.provider, period: slot.period)
                        }
                    }.frame(maxWidth: .infinity, alignment: .top)
                }
            }
            if model.enabledProviders.count == 1, let provider = model.enabledProviders.first {
                QuotaProviderStatusView(model: model, provider: provider, period: nil)
                    .frame(maxWidth: .infinity)
            }
        }.padding(.bottom, 6)
    }

    private func providerHelp(_ provider: AgentProvider, period: QuotaDashboardPeriod) -> String {
        var details = [model.providerSourceText(provider), model.providerFreshnessText(provider, period: period)]
        if provider == .claude, model.claudeQuotaSource == .oauthUsage {
            details.append(L10n.text("claude.quota.source_service_help"))
        }
        return details.compactMap { $0 }.joined(separator: "\n")
    }
}

private struct LegacyCodexQuotaView: View {
    @ObservedObject var model: IslandModel
    let snapshot: QuotaSnapshot
    private let secondary = Color(red: 0.66, green: 0.68, blue: 0.71)
    private var fresh: Bool { !model.providerQuotaIsStale(.codex) && model.providerQuotaError(.codex) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 5) {
                Text(AgentProvider.codex.displayName).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentProvider.codex.tint)
                if !fresh {
                    Image(systemName: StatusSymbols.freshness).font(.system(size: 9)).foregroundStyle(.orange)
                        .accessibilityLabel(L10n.text("common.not_updated"))
                }
            }.help([model.providerSourceText(.codex), model.providerFreshnessText(.codex)].compactMap { $0 }.joined(separator: "\n"))
            ForEach(snapshot.buckets) { bucket in
                if !bucket.windows.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        if snapshot.buckets.count > 1 {
                            Text(bucket.name ?? bucket.id).font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                        }
                        ForEach(bucket.windows) { window in
                            QuotaWindowView(window: window, now: model.now,
                                allowPace: fresh, accent: fresh ? AgentProvider.codex.tint : secondary, secondary: secondary)
                        }
                    }
                }
            }
            QuotaProviderStatusView(model: model, provider: .codex, period: nil).frame(maxWidth: .infinity)
        }.padding(.bottom, 6)
    }
}

private struct QuotaDashboardRingView: View {
    let quota: QuotaDashboardQuota
    let title: String
    let providerHelp: String
    let now: Date
    private let secondary = Color(red: 0.66, green: 0.68, blue: 0.71)
    private var stale: Bool { quota.availability == .stale }
    private var proOnly: Bool { quota.availability == .proOnly }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(quota.provider.tint)
                if stale {
                    Image(systemName: StatusSymbols.freshness).font(.system(size: 9)).foregroundStyle(.orange)
                        .accessibilityLabel(L10n.text("common.not_updated"))
                }
            }.frame(height: 16).help(detailsHelp)
            ZStack {
                if proOnly {
                    let platinum = Color(red: 0.86, green: 0.88, blue: 0.91)
                    Circle().stroke(platinum.opacity(0.28), lineWidth: 0.7)
                    Text(L10n.text("dashboard.pro"))
                        .font(.system(size: 17, weight: .medium)).tracking(1.5).foregroundStyle(platinum)
                } else {
                    ring(percent: quota.remainingQuotaPercent, lineWidth: 4, color: quota.provider.tint)
                    ring(percent: quota.remainingTimePercent, lineWidth: 1.5, color: secondary.opacity(0.85))
                        .padding(11)
                    VStack(spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(percentText(quota.remainingQuotaPercent).replacingOccurrences(of: "%", with: ""))
                                .font(.system(size: 30, weight: .medium)).tracking(-0.7)
                            if let percent = quota.remainingQuotaPercent, percent.isFinite {
                                Text("%").font(.system(size: 14, weight: .regular)).foregroundStyle(secondary)
                            }
                        }.monospacedDigit().foregroundStyle(.primary)
                        HStack(spacing: 3) {
                            Image(systemName: "clock").font(.system(size: 8))
                            Text(countdown).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.foregroundStyle(secondary).help(resetDate)
                    }
                    .frame(maxWidth: 80)
                }
            }
            .frame(width: 116, height: 116)
            .opacity(stale ? 0.5 : 1)
            .help(detailsHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(detailsHelp)
        }.frame(maxWidth: .infinity)
    }

    private func ring(percent: Double?, lineWidth: CGFloat, color: Color) -> some View {
        let fraction = percent.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
        return ZStack {
            Circle().stroke(Color.white.opacity(fraction == nil ? 0.16 : 0.07),
                style: StrokeStyle(lineWidth: lineWidth, dash: fraction == nil ? [2, 5] : []))
            if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: CGFloat(fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.accessibilityHidden(true)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }

    private var accessibilityLabel: String {
        let provider = quota.bucketName.map { quota.provider.displayName + " " + $0 } ?? quota.provider.displayName
        if proOnly { return provider + ", " + quota.period.accessibilityLabel + ". " + L10n.text("dashboard.pro_help") }
        let quotaText = quota.remainingQuotaPercent == nil ? L10n.text("common.unknown") : percentText(quota.remainingQuotaPercent)
        let timeText = quota.remainingTimePercent == nil ? L10n.text("common.unknown") : percentText(quota.remainingTimePercent)
        return L10n.text("dashboard.rings_accessibility", provider, quota.period.accessibilityLabel,
            quotaText, timeText, resetDate + ". " + quota.freshnessText)
    }

    private var detailsHelp: String {
        var details = [L10n.text(proOnly ? "dashboard.pro_help" : "dashboard.rings_help")]
        if let name = quota.bucketName { details.append(name) }
        if quota.availability == .missingPeriod {
            details.append(L10n.text("dashboard.period_unavailable", quota.period.accessibilityLabel))
        }
        if !proOnly {
            details.append(L10n.text("dashboard.time_remaining", percentText(quota.remainingTimePercent)))
            details.append(resetDate)
        }
        details.append(providerHelp)
        return details.joined(separator: "\n")
    }

    private var countdown: String {
        guard let seconds = quota.window?.remainingSeconds(at: now) else { return "—" }
        if seconds <= 0 { return L10n.text("dashboard.countdown_waiting") }
        if seconds < 60 { return L10n.text("dashboard.countdown_soon") }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("dashboard.countdown_days", days, hours) }
        if hours > 0 { return L10n.text("dashboard.countdown_hours", hours, minutes) }
        return L10n.text("dashboard.countdown_minutes", minutes)
    }
    private var resetDate: String {
        quota.window?.resetsAt.map { L10n.text("quota.reset_date", L10n.date($0)) } ?? L10n.text("quota.reset_unknown")
    }
}

private struct QuotaProviderStatusView: View {
    @ObservedObject var model: IslandModel
    let provider: AgentProvider
    let period: QuotaDashboardPeriod?
    private let secondary = Color(red: 0.66, green: 0.68, blue: 0.71)

    var body: some View {
        VStack(spacing: 6) {
            if let error = model.providerQuotaError(provider) {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                connectionActions
            } else if model.providerQuota(provider)?.windows.isEmpty != false {
                Text(model.providerRefreshing(provider) ? L10n.text("quota.loading") : L10n.text("dashboard.provider_unavailable", provider.displayName))
                    .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("common.open_settings")) { model.onSettings?() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(provider.tint)
            }
        }.multilineTextAlignment(.center)
    }

    private var connectionActions: some View {
        VStack(spacing: 7) {
            if provider == .claude, model.claudeConnectionNeeded {
                Button(L10n.text(model.claudeConnectionActionTitleKey)) { model.connectClaudeQuota() }
                    .help(L10n.text(model.claudeConnectionActionHelpKey)).disabled(model.providerRefreshing(provider))
            }
            HStack(spacing: 12) {
                Button(L10n.text(model.providerRefreshing(provider) ? "common.retrying" : "common.retry")) {
                    model.retryQuotaConnection(for: provider)
                }.disabled(model.providerRefreshing(provider))
                Button(L10n.text("common.settings")) { model.onSettings?() }
            }
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(provider.tint)
    }
}
