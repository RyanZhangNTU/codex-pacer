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
}
