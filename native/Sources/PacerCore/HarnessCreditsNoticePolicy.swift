import Foundation

/// Account credits notify once when they fall to the low line, once when they
/// run out, and once when extra credits are about to lapse. Another low notice
/// waits until the credits recover with room to spare.
public struct HarnessCreditsNoticePolicy: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case low, exhausted }

    private var notified: [AgentProvider: Level] = [:]
    /// The lapse date already announced, so each batch notifies once.
    private var expiryNotified: [AgentProvider: Date] = [:]

    public init() {}

    /// Low is at or below the user's line, which defaults to a tenth of the month's credits.
    public static func level(_ reading: HarnessAccountCredits.Reading, settings: HarnessCreditsSettings = .default) -> Level? {
        if reading.remaining <= 0 { return .exhausted }
        return reading.remaining <= reading.lowLine(settings) ? .low : nil
    }

    /// `low` follows the low-credits reminder; running out always notifies;
    /// lapsing extra credits follow each module's own expiry reminder.
    public mutating func notices(_ credits: [AgentProvider: HarnessAccountCredits], settings: [AgentProvider: HarnessCreditsSettings] = [:],
                                 low: Bool, now: Date) -> [IslandNotice] {
        var result: [IslandNotice] = []
        for provider in HarnessRegistry.ids(where: \.reportsAccountCredits) {
            guard let reading = credits[provider]?.reading(at: now) else { continue }
            let options = settings[provider] ?? .default
            if options.expiryReminder, let soon = reading.expiringSoon(within: options.expiryDays, at: now) {
                if expiryNotified[provider] != soon.date {
                    expiryNotified[provider] = soon.date
                    result.append(.init(id: provider.rawValue + ":credits:expiring:" + String(Int(soon.date.timeIntervalSince1970)), kind: .lowQuota,
                        title: provider.displayName + " · " + L10n.text("harness.notice.expiring_credits"),
                        detail: L10n.text("harness.notice.expiring_credits_detail", HarnessCreditsPresentation.grouped(soon.credits),
                                          L10n.moment(soon.date, relativeTo: now))))
                }
            } else if reading.extra.map({ $0.remaining <= 0 || !$0.batches.isEmpty }) ?? true {
                // Forget the date only when the bill's batches say nothing lapses
                // soon; a reading without them (a slow detail request) proves nothing.
                expiryNotified[provider] = nil
            }
            let level = Self.level(reading, settings: options)
            if level == nil {
                if reading.remaining > reading.lowLine(options) * 2 { notified[provider] = nil }
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
    public mutating func reset(_ provider: AgentProvider) { notified[provider] = nil; expiryNotified[provider] = nil }
}
