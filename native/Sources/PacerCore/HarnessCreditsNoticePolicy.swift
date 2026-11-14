import Foundation

/// Account credits notify once when they fall to the low line and once when
/// they run out. Another low notice waits until they recover with room to spare.
public struct HarnessCreditsNoticePolicy: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case low, exhausted }
    /// Percent of the plan cycle, or of all credits, that counts as low.
    public static let lowPercent = 10.0
    /// Above this the low notice can fire again.
    public static let recoveredPercent = 20.0

    private var notified: [AgentProvider: Level] = [:]

    public init() {}

    public static func level(_ reading: HarnessAccountCredits.Reading) -> Level? {
        if reading.remaining <= 0 { return .exhausted }
        guard let percent = reading.percent else { return nil }
        return percent <= lowPercent ? .low : nil
    }

    /// `low` follows the low-credits reminder; running out always notifies.
    public mutating func notices(_ credits: [AgentProvider: HarnessAccountCredits], low: Bool, now: Date) -> [IslandNotice] {
        var result: [IslandNotice] = []
        for provider in HarnessRegistry.ids(where: \.reportsAccountCredits) {
            guard let reading = credits[provider]?.reading(at: now) else { continue }
            let level = Self.level(reading)
            if level == nil {
                if reading.percent.map({ $0 > Self.recoveredPercent }) ?? true { notified[provider] = nil }
                continue
            }
            guard let level, notified[provider] != level, notified[provider] != .exhausted || level == .exhausted else { continue }
            notified[provider] = level
            guard level == .exhausted || low else { continue }
            let exhausted = level == .exhausted
            result.append(.init(id: provider.rawValue + ":credits:" + (exhausted ? "exhausted" : "low"), kind: .lowQuota,
                title: provider.displayName + " · " + L10n.text(exhausted ? "harness.notice.no_credits" : "harness.notice.low_credits"),
                detail: exhausted ? L10n.text("harness.notice.no_credits_detail")
                    : L10n.text("harness.notice.low_credits_detail", HarnessAccountCredits.compactAmount(reading.remaining))))
        }
        return result
    }

    /// Forget a module's notices, as after signing out or turning it off.
    public mutating func reset(_ provider: AgentProvider) { notified[provider] = nil }
}
