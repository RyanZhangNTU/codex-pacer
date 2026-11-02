import Foundation

/// The Settings history section uses the same window readings as the island,
/// while preserving empty buckets and each window's own pacing eligibility.
public struct QuotaHistoryPresentation: Codable, Equatable, Sendable {
    public let title: String
    public let sourceText: String?
    public let freshnessText: String
    public let notUpdated: Bool
    public let errorText: String?
    public let placeholder: String?
    public let chart: QuotaCycleChartPresentation?
    public let buckets: [QuotaDashboardPresentation.LegacyBucket]
    public let account: QuotaAccountPresentation?
    public let warning: String?
    public let refreshTitle: String
    public let refreshing: Bool

    public init(provider: AgentProvider, snapshot: QuotaSnapshot?, weekly: QuotaDashboardPresentation.Reading,
                chart: QuotaCycleChartPresentation?, error: String?, warning: String?, refreshing: Bool,
                accountContext: String, now: Date) {
        title = L10n.text("settings.quota_history", provider.displayName)
        sourceText = weekly.sourceText; freshnessText = weekly.freshnessText
        notUpdated = snapshot?.isStale(at: now) == true || weekly.resetsAt.map { $0 <= now.timeIntervalSince1970 } == true || error != nil
        errorText = error; self.warning = warning; self.refreshing = refreshing
        refreshTitle = L10n.text(refreshing ? "common.retrying" : "common.refresh")
        self.chart = snapshot == nil ? nil : chart
        if let snapshot {
            placeholder = chart == nil && weekly.windowID != nil ? L10n.text("quota.waiting_sample") : nil
            buckets = snapshot.buckets.map { bucket in
                .init(id: bucket.id, title: snapshot.buckets.count > 1 ? bucket.name ?? bucket.id : nil,
                    windows: bucket.windows.map { window in
                        .init(window: window, allowPace: !snapshot.isStale(at: now) && error == nil && window.resetsAt.map { $0 > now } == true, now: now)
                    })
            }
            account = provider == .codex || snapshot.credits != nil || snapshot.resetCredits != nil
                ? QuotaAccountPresentation(snapshot: snapshot, context: accountContext, now: now) : nil
        } else {
            placeholder = refreshing ? L10n.text("quota.loading") : L10n.text("quota.not_connected", provider.displayName)
            buckets = []; account = nil
        }
    }
}

/// Formatted account usage contains no account scope or reset-credit identity.
/// Context is an opaque, process-local token supplied by the owning source.
public struct QuotaAccountPresentation: Codable, Equatable, Sendable {
    public struct Expiry: Codable, Equatable, Sendable {
        public let timestamp: Double
        public let dateText: String
        public let countText: String
        public let accessibilityLabel: String
    }
    public let context: String
    public let resetText: String
    public let expirySoon: Bool
    public let expiryDescription: String
    public let resetsAccessibility: String
    public let balanceText: String
    public let balanceAccessibility: String
    public let detailMessage: String?
    public let expiries: [Expiry]
    public let nonExpiringText: String?
    public let unknownText: String?
    public let timeZoneText: String?

    public init(snapshot: QuotaSnapshot, context: String, now: Date) {
        self.context = context
        let summary = snapshot.resetCredits
        let count = summary?.remainingCount(at: now, capturedAt: snapshot.capturedAt)
        let expiry = summary?.nextExpiry(at: now)
        resetText = count.map { L10n.text("account.reset_count", $0) } ?? L10n.text("account.resets_unknown")
        expirySoon = expiry.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false
        if count == 0 { expiryDescription = L10n.text("account.no_resets") }
        else if let expiry {
            expiryDescription = L10n.text(summary?.hasCompleteDetails == false ? "account.known_expiry" : "account.next_expiry", L10n.date(expiry, date: .complete))
        } else { expiryDescription = L10n.text(summary?.hasNoExpiringCredits(at: now) == true ? "account.no_expiry" : "account.expiry_unknown") }
        resetsAccessibility = L10n.text("account.resets_accessibility", count.map(String.init) ?? L10n.text("common.unknown"), expiryDescription)
        if let credits = snapshot.credits, credits.unlimited { balanceText = L10n.text("common.unlimited") }
        else if let amount = snapshot.credits?.amount {
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.locale = L10n.locale; formatter.maximumFractionDigits = 2
            balanceText = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
        } else { balanceText = "—" }
        balanceAccessibility = L10n.text("account.credit_balance", balanceText)
        let details = summary?.expiryDetails(at: now, capturedAt: snapshot.capturedAt)
        detailMessage = count == 0 ? L10n.text("account.no_resets") : details == nil ? L10n.text("account.expiry_unknown") : nil
        expiries = count == 0 ? [] : (details?.expiries ?? []).map { expiry in
            let date = L10n.date(expiry.date, time: .standard)
            return Expiry(timestamp: expiry.date.timeIntervalSince1970, dateText: date,
                countText: L10n.text("chart.expiry_count", expiry.count), accessibilityLabel: L10n.text("chart.expiry_item", expiry.count, date))
        }
        nonExpiringText = count != 0 && (details?.nonExpiringCount ?? 0) > 0 ? L10n.text("account.non_expiring_count", details!.nonExpiringCount) : nil
        unknownText = count != 0 && (details?.unknownCount ?? 0) > 0 ? L10n.text("account.unknown_expiry_count", details!.unknownCount) : nil
        timeZoneText = expiries.isEmpty ? nil : L10n.text("account.expiry_timezone", TimeZone.current.identifier)
    }
}
