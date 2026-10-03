import Foundation

/// Only values that change the curve or its expiry markers participate in view equality.
public struct QuotaChartData: Equatable, Sendable {
    public struct ResetExpiry: Equatable, Sendable, Identifiable {
        public let date: Date
        public let count: Int
        public var id: Date { date }
    }

    public let startedAt: Date
    public let resetsAt: Date
    public let points: [QuotaPoint]
    public let expiries: [ResetExpiry]
    public let hasPartialExpiryDetails: Bool

    public init(cycle: QuotaCycle, resetCredits: QuotaResetSummary?, now: Date) {
        startedAt = cycle.startedAt
        resetsAt = cycle.resetsAt
        points = cycle.displayPoints()
        hasPartialExpiryDetails = resetCredits?.hasCompleteDetails == false
        var seen = Set<String>()
        let dates = (resetCredits?.credits ?? []).compactMap { credit -> Date? in
            guard credit.status == "available", let date = credit.expiresAt,
                  date > now, date >= cycle.startedAt, date <= cycle.resetsAt,
                  seen.insert(credit.id).inserted else { return nil }
            return date
        }
        expiries = Dictionary(grouping: dates, by: { $0 })
            .map { ResetExpiry(date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }
}
