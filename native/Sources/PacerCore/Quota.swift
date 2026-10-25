import Foundation

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public var remainingPercent: Double? { usedPercent.map { 100 - min(100, max(0, $0)) } }
    public var label: String {
        guard let minutes = durationMinutes, minutes > 0 else { return L10n.text("quota.generic_window") }
        if minutes % 1440 == 0 { return L10n.text("quota.days", minutes / 1440) }
        if minutes % 60 == 0 { return L10n.text("quota.hours", minutes / 60) }
        return L10n.text("quota.minutes", minutes)
    }
    public func remainingTimePercent(at now: Date) -> Double? {
        guard let minutes = durationMinutes, minutes > 0, let reset = resetsAt, reset > now else { return nil }
        return min(100, max(0, reset.timeIntervalSince(now) / (Double(minutes) * 60) * 100))
    }
    public func elapsedTimePercent(at now: Date) -> Double? {
        guard let minutes = durationMinutes, minutes > 0, let reset = resetsAt else { return nil }
        let remaining = reset.timeIntervalSince(now) / (Double(minutes) * 60) * 100
        return min(100, max(0, 100 - remaining))
    }
    public func remainingSeconds(at now: Date) -> TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSince(now)) }
    }
    /// Same remaining-quota / remaining-time formula as the original app.
    public func pacePercent(at now: Date) -> Double? {
        guard let remaining = remainingPercent, let time = remainingTimePercent(at: now), time > 0 else { return nil }
        return min(1000, remaining / time * 100)
    }
    /// Extends the average spend since the window opened to its reset. In the
    /// first 5% of the window the spend so far says too little to project.
    public func projection(at now: Date) -> QuotaProjection? {
        guard let remaining = remainingPercent, let time = remainingTimePercent(at: now),
              let minutes = durationMinutes, minutes > 0 else { return nil }
        if remaining <= 0 { return .runsOut(after: 0) }
        let elapsed = 100 - time, used = 100 - remaining
        guard elapsed >= 5 else { return .tooEarly }
        guard used > 0 else { return .remainingAtReset(remaining) }
        let rate = used / elapsed, left = remaining - rate * time
        return left >= 0 ? .remainingAtReset(left) : .runsOut(after: remaining / rate / 100 * Double(minutes) * 60)
    }

    public init(id: String, usedPercent: Double?, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.usedPercent = usedPercent?.isFinite == true ? usedPercent : nil
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }
}

/// Where the spend so far leads by the window's reset.
public enum QuotaProjection: Equatable, Sendable {
    case tooEarly
    case remainingAtReset(Double)
    case runsOut(after: TimeInterval)
}

public struct QuotaBucket: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let plan: String?
    public let windows: [QuotaWindow]
    public let credits: CreditBalance?
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let buckets: [QuotaBucket]
    public let capturedAt: Date
    public var accountScope: String?
    public let resetCredits: QuotaResetSummary?
    public var credits: CreditBalance? {
        if let codex = buckets.first(where: { $0.id == "codex" }) { return codex.credits }
        return buckets.first?.credits
    }

    public var windows: [QuotaWindow] { buckets.flatMap(\.windows) }
    public var limitingWindow: QuotaWindow? {
        windows.filter { $0.remainingPercent != nil }.min { $0.remainingPercent! < $1.remainingPercent! }
    }
    public func isStale(at now: Date = Date(), interval: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(capturedAt) > interval
    }

    public static func decode(_ data: Data, capturedAt: Date = Date()) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(WireResponse.self, from: data)
        let sources: [(String, WireBucket)]
        if let multiple = response.rateLimitsByLimitId, !multiple.isEmpty {
            sources = multiple.sorted { lhs, rhs in
                if lhs.key == "codex" { return rhs.key != "codex" }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }.map { ($0.key, $0.value) }
        } else if let single = response.rateLimits {
            sources = [(single.limitId ?? "codex", single)]
        } else {
            sources = []
        }
        let buckets = sources.map { key, bucket in
            let id = bucket.limitId ?? key
            let windows = [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { lane, wire -> QuotaWindow? in
                guard let wire else { return nil }
                return QuotaWindow(id: "\(id)/\(lane)", usedPercent: wire.usedPercent,
                    durationMinutes: wire.windowDurationMins,
                    resetsAt: wire.resetsAt.map { Date(timeIntervalSince1970: $0) })
            }
            return QuotaBucket(id: id, name: bucket.limitName, plan: bucket.planType, windows: windows, credits: bucket.credits?.value)
        }
        let reset = response.rateLimitResetCredits?.value.flatMap { summary -> QuotaResetSummary? in
            guard summary.availableCount >= 0 else { return nil }
            return QuotaResetSummary(availableCount: summary.availableCount, credits: summary.credits?.map {
                QuotaResetCredit(id: $0.id, status: $0.status,
                    expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: $0) },
                    grantedAt: Date(timeIntervalSince1970: $0.grantedAt))
            })
        }
        return QuotaSnapshot(buckets: buckets, capturedAt: capturedAt, accountScope: nil, resetCredits: reset)
    }
}

private struct WireResponse: Decodable {
    let rateLimits: WireBucket?
    let rateLimitsByLimitId: [String: WireBucket]?
    let rateLimitResetCredits: OptionalValue<WireResetSummary>?
}
private struct WireBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: WireWindow?
    let secondary: WireWindow?
    let credits: OptionalValue<CreditBalance>?
}
private struct WireWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

/// Unavailable optional billing metadata must not break the quota display.
private struct OptionalValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
private struct WireResetSummary: Decodable {
    let availableCount: Int
    let credits: [WireResetCredit]?
}
private struct WireResetCredit: Decodable {
    let id: String
    let status: String
    let grantedAt: Double
    let expiresAt: Double?
}
