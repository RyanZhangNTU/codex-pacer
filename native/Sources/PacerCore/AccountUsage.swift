import Foundation

public struct CreditBalance: Codable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
    public var amount: Decimal? {
        guard let balance,
              balance.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct QuotaResetCredit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let expiresAt: Date?
    public let grantedAt: Date
}

public struct QuotaResetSummary: Codable, Equatable, Sendable {
    /// The backend can cap the detail list; its length is not the available count.
    public let availableCount: Int
    public let credits: [QuotaResetCredit]?

    public func remainingCount(at now: Date, capturedAt: Date) -> Int {
        let newlyExpired = Set((credits ?? []).filter {
            $0.status == "available" && $0.expiresAt.map { $0 > capturedAt && $0 <= now } == true
        }.map(\.id)).count
        return max(0, availableCount - newlyExpired)
    }
    public func nextExpiry(at now: Date) -> Date? {
        (credits ?? []).filter { $0.status == "available" }.compactMap(\.expiresAt).filter { $0 > now }.min()
    }
    public var hasCompleteDetails: Bool {
        guard let credits else { return false }
        return Set(credits.filter { $0.status == "available" }.map(\.id)).count >= availableCount
    }
    public func hasNoExpiringCredits(at now: Date) -> Bool {
        let active = (credits ?? []).filter {
            $0.status == "available" && ($0.expiresAt == nil || $0.expiresAt! > now)
        }
        return hasCompleteDetails && !active.isEmpty && active.allSatisfy { $0.expiresAt == nil }
    }

    /// All available deadlines, including those outside the displayed quota cycle.
    /// Missing rows remain unknown rather than inheriting another credit's expiry.
    public func expiryDetails(at now: Date, capturedAt: Date) -> QuotaResetExpiryDetails {
        let remaining = remainingCount(at: now, capturedAt: capturedAt)
        var seen = Set<String>()
        let active = (credits ?? []).filter {
            $0.status == "available" && ($0.expiresAt == nil || $0.expiresAt! > now)
        }.sorted {
            let left = $0.expiresAt ?? .distantFuture, right = $1.expiresAt ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }.filter { seen.insert($0.id).inserted }.prefix(remaining)
        let deadlines = active.compactMap(\.expiresAt)
        let expiries = Dictionary(grouping: deadlines, by: { $0 })
            .map { QuotaResetExpiryDetails.Expiry(date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
        return QuotaResetExpiryDetails(expiries: expiries,
            nonExpiringCount: active.filter { $0.expiresAt == nil }.count,
            unknownCount: max(0, remaining - active.count))
    }
}

public struct QuotaResetExpiryDetails: Equatable, Sendable {
    public struct Expiry: Equatable, Sendable, Identifiable {
        public let date: Date
        public let count: Int
        public var id: Date { date }
    }
    public let expiries: [Expiry]
    public let nonExpiringCount: Int
    public let unknownCount: Int
}
