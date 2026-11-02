import Foundation

extension QuotaDashboardPresentation {
    /// Original Codex-only bars preserve every reported bucket and window.
    /// Their freshness follows the selected collapsed window, as on macOS.
    public struct Legacy: Codable, Equatable, Sendable {
        public let fresh: Bool
        public let freshnessText: String
        public let help: String
        public let buckets: [LegacyBucket]

        public init(snapshot: QuotaSnapshot, failed: Bool = false, selectedWindowID: String? = nil, now: Date) {
            let own = snapshot.buckets.first { $0.id == "codex" } ?? snapshot.buckets.first
            let selection = QuotaWindowSelection(saved: selectedWindowID, snapshot: snapshot)
            let selected = (selection == .fiveHour ? own?.windows.first { $0.durationMinutes == 300 } : nil)
                ?? own?.windows.first { $0.durationMinutes == 10080 }
                ?? snapshot.windows.first { $0.durationMinutes == 10080 } ?? snapshot.limitingWindow
            let expired = selected?.resetsAt.map { $0 <= now } == true
            let fresh = !snapshot.isStale(at: now) && !expired && !failed
            self.fresh = fresh
            let elapsed = max(0, Int(now.timeIntervalSince(snapshot.capturedAt)))
            if expired { freshnessText = L10n.text("quota.expired") }
            else if snapshot.isStale(at: now) { freshnessText = L10n.text("quota.age", max(1, elapsed / 60)) }
            else { freshnessText = elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60) }
            help = [L10n.text("quota.source_codex"), freshnessText].joined(separator: "\n")
            buckets = snapshot.buckets.filter { !$0.windows.isEmpty }.map { bucket in
                LegacyBucket(id: bucket.id, title: snapshot.buckets.count > 1 ? bucket.name ?? bucket.id : nil,
                    windows: bucket.windows.map { LegacyWindow(window: $0, allowPace: fresh, now: now) })
            }
        }
    }
    public struct LegacyBucket: Codable, Equatable, Sendable {
        public let id: String
        public let title: String?
        public let windows: [LegacyWindow]
    }
    public struct LegacyWindow: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let remainingPercent: Double?
        public let remainingTimePercent: Double?
        public let pacePercent: Double?
        public let valueText: String
        public let countdown: String
        public let resetDate: String
        public let paceText: String
        public let accessibilityLabel: String
        public init(window: QuotaWindow, allowPace: Bool, now: Date) {
            id = window.id; label = window.label
            remainingPercent = window.remainingPercent
            remainingTimePercent = allowPace ? window.remainingTimePercent(at: now) : nil
            pacePercent = allowPace ? window.pacePercent(at: now) : nil
            valueText = remainingPercent.map { String(Int($0.rounded())) } ?? "—"
            countdown = window.remainingSeconds(at: now).map(Self.countdown) ?? L10n.text("quota.reset_unknown")
            resetDate = window.resetsAt.map { L10n.text("quota.reset_date", L10n.date($0)) } ?? L10n.text("quota.reset_unknown")
            paceText = pacePercent.map { L10n.text("quota.pace_value", Int($0.rounded())) } ?? L10n.text("quota.pace_unknown")
            accessibilityLabel = [label, remainingPercent.map { L10n.text("quota.remaining", Int($0.rounded())) } ?? "—", countdown, paceText].joined(separator: ", ")
        }
        private static func countdown(_ seconds: TimeInterval) -> String {
            if seconds <= 0 { return L10n.text("quota.waiting_update") }
            if seconds < 60 { return L10n.text("quota.reset_soon") }
            let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
            if days > 0 { return L10n.text("quota.reset_days", days, hours) }
            if hours > 0 { return L10n.text("quota.reset_hours", hours, minutes) }
            return L10n.text("quota.reset_minutes", minutes)
        }
    }
}
