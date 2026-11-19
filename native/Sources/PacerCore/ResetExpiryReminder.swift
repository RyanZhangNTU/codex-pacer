import Foundation

/// Codex banked resets that expire within the reminder's lead time. The
/// collapsed bar's warning and the system notification read the same deadlines.
public enum ResetExpiryReminder {
    /// Days ahead that count as soon, like credits' expiry reminder; a day by default.
    public static let leadDayRange = 1...30
    public static let defaultLeadDays = 1
    public static let defaultsKey = "codexResetExpiryDays"
    /// The last hours before a deadline that mark the warning as needing the user.
    public static let urgentInterval: TimeInterval = 3 * 3600
    public static let symbol = "arrow.counterclockwise"

    /// A saved or requested lead time; anything outside the range is the default.
    public static func leadDays(_ value: Int?) -> Int { value.flatMap { leadDayRange.contains($0) ? $0 : nil } ?? defaultLeadDays }

    /// Known deadlines of available resets inside the lead time, soonest first.
    public static func due(_ snapshot: QuotaSnapshot?, leadDays: Int, now: Date) -> [QuotaResetExpiryDetails.Expiry] {
        guard let snapshot, let summary = snapshot.resetCredits,
              summary.remainingCount(at: now, capturedAt: snapshot.capturedAt) > 0 else { return [] }
        let lead = TimeInterval(Self.leadDays(leadDays)) * 86400
        return summary.expiryDetails(at: now, capturedAt: snapshot.capturedAt).expiries.filter {
            $0.date > now && $0.date.timeIntervalSince(now) <= lead
        }
    }

    /// "2 Codex resets expire in 23h 10m (Nov 21, 08:00)." for these deadlines.
    public static func help(_ expiries: [QuotaResetExpiryDetails.Expiry], now: Date) -> String? {
        guard let first = expiries.min(by: { $0.date < $1.date }) else { return nil }
        let count = expiries.reduce(0) { $0 + $1.count }
        return L10n.text("warning.reset_expiry_help", count, CompactDuration.text(first.date.timeIntervalSince(now)),
            L10n.date(first.date, time: .standard))
    }

    /// The collapsed bar's mark for the nearest deadline inside the lead time.
    public static func warning(_ snapshot: QuotaSnapshot?, leadDays: Int, now: Date) -> CompactWarningPresentation.Item? {
        let due = due(snapshot, leadDays: leadDays, now: now)
        guard let first = due.first, let help = help(due, now: now) else { return nil }
        return .init(kind: .resetExpiry, provider: AgentProvider.codex.rawValue,
            solid: first.date.timeIntervalSince(now) <= urgentInterval, label: nil, symbol: symbol, help: help)
    }
}

/// One notification when deadlines enter the lead time, for the account that
/// owns them. Like the quota notices it keeps no record across launches, so a
/// deadline already inside the lead time notifies once after a relaunch.
public struct ResetExpiryNoticePolicy: Sendable {
    private var scope: String?
    private var notified: Set<Int> = []
    public init() {}

    public mutating func notices(_ snapshot: QuotaSnapshot?, leadDays: Int, now: Date) -> [IslandNotice] {
        guard let snapshot else { return [] }
        if scope != snapshot.accountScope { notified.removeAll(); scope = snapshot.accountScope }
        let due = ResetExpiryReminder.due(snapshot, leadDays: leadDays, now: now)
        func key(_ expiry: QuotaResetExpiryDetails.Expiry) -> Int { Int(expiry.date.timeIntervalSince1970 / 60) }
        // A deadline that passed or left a shortened lead time may remind again later.
        notified.formIntersection(due.map(key))
        let fresh = due.filter { !notified.contains(key($0)) }
        guard let first = fresh.first, let detail = ResetExpiryReminder.help(fresh, now: now) else { return [] }
        notified.formUnion(fresh.map(key))
        return [IslandNotice(id: "codex:reset-expiry:\(key(first))", kind: .lowQuota,
            title: L10n.text("notice.reset_expiry"), detail: detail)]
    }
}
