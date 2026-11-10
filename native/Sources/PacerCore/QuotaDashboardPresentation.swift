import Foundation

/// Dashboard decisions and localized readings used by both native interfaces.
public enum QuotaDashboardPresentation {
    public enum Verdict: String, Codable, Sendable {
        case spare, steady, fast
        public init(pace: Double) { self = pace < 85 ? .fast : pace > 115 ? .spare : .steady }
        public var label: String { L10n.text("quota.verdict." + rawValue) }
    }
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case split, classic
        public var id: String { rawValue }
        public var label: String { L10n.text("appearance.quota_" + rawValue) }
    }
    public enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
        case fiveHour = "5h", weekly = "7d"
        public var id: String { rawValue }
        public var label: String { self == .fiveHour ? L10n.text("quota.compact_hours", 5) : L10n.text("quota.compact_days", 7) }
        public var durationMinutes: Int { minutes }
        public var minutes: Int { self == .fiveHour ? 300 : 10080 }
        public var accessibilityLabel: String { self == .fiveHour ? L10n.text("quota.hours", 5) : L10n.text("quota.days", 7) }
    }
    public enum Availability: String, Codable, Sendable { case available, stale, unavailable, missingPeriod, proOnly }
    public enum Kind: String, Codable, Sendable { case splitRings, splitSingle, classicRings, legacyCodex, deepseekSolo }
    public struct Slot: Codable, Equatable, Identifiable, Sendable {
        public let provider: AgentProvider
        public let period: Period
        public let identifiesProvider: Bool
        public let id: String
        public let title: String
        public init(provider: AgentProvider, period: Period, identifiesProvider: Bool) {
            self.provider = provider; self.period = period; self.identifiesProvider = identifiesProvider
            id = provider.rawValue + ":" + period.rawValue
            title = identifiesProvider ? provider.displayName : period.rawValue
        }
    }
    public struct Layout: Codable, Equatable, Sendable {
        public let kind: Kind
        public let slots: [Slot]
    }
    public static func bucket(provider: AgentProvider, snapshot: QuotaSnapshot?) -> QuotaBucket? {
        snapshot.flatMap { value in value.buckets.first { $0.id == provider.rawValue } ?? value.buckets.first }
    }
    public static func window(provider: AgentProvider, snapshot: QuotaSnapshot?, period: Period) -> QuotaWindow? {
        bucket(provider: provider, snapshot: snapshot)?.windows.first { $0.durationMinutes == period.minutes }
    }
    public static func isWeeklyOnly(provider: AgentProvider, snapshot: QuotaSnapshot?) -> Bool {
        window(provider: provider, snapshot: snapshot, period: .weekly) != nil && window(provider: provider, snapshot: snapshot, period: .fiveHour) == nil
    }
    public static func isStale(snapshot: QuotaSnapshot?, window: QuotaWindow?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return snapshot.isStale(at: now) || window?.resetsAt.map { $0 <= now } == true
    }
    public static func freshness(snapshot: QuotaSnapshot?, window: QuotaWindow?, failed: Bool = false, refreshing: Bool = false, now: Date) -> String {
        guard let snapshot else { return L10n.text(refreshing ? "quota.reading" : "quota.not_read") }
        if window?.resetsAt.map({ $0 <= now }) == true { return L10n.text("quota.expired") }
        let elapsed = max(0, Int(now.timeIntervalSince(snapshot.capturedAt)))
        if isStale(snapshot: snapshot, window: window, now: now) || failed { return L10n.text("quota.age", max(1, elapsed / 60)) }
        return elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
    }
    public static func selectedWindow(provider: AgentProvider, snapshot: QuotaSnapshot?, selection: String?) -> QuotaWindow? {
        guard let snapshot else { return nil }
        let windows = bucket(provider: provider, snapshot: snapshot)?.windows ?? []
        if QuotaWindowSelection(saved: selection, snapshot: snapshot) == .fiveHour,
           let window = windows.first(where: { $0.durationMinutes == 300 }) { return window }
        return windows.first { $0.durationMinutes == 10080 } ?? snapshot.windows.first { $0.durationMinutes == 10080 } ?? snapshot.limitingWindow
    }
    /// `preservingOrder` keeps the panel's block order instead of the services'
    /// usual one. `periods` limits which windows each service draws: Classic
    /// shows one ring per window for a lone service, and one ring per service
    /// otherwise, on the week unless only 5 hours is chosen.
    public static func slots(providers: [AgentProvider], style: Style, preservingOrder: Bool = false,
                             periods: (AgentProvider) -> ExpandedPanelOptions.Periods = { _ in .both }) -> [Slot] {
        let ordered = order(providers, preservingOrder: preservingOrder)
        if style == .classic, let provider = ordered.first, ordered.count == 1 {
            let chosen = periods(provider)
            return Period.allCases.filter { chosen == .both || (chosen == .weekly) == ($0 == .weekly) }
                .map { Slot(provider: provider, period: $0, identifiesProvider: false) }
        }
        return ordered.map {
            Slot(provider: $0, period: style == .classic && periods($0) == .fiveHour ? .fiveHour : .weekly, identifiesProvider: style == .classic)
        }
    }
    private static func order(_ providers: [AgentProvider], preservingOrder: Bool) -> [AgentProvider] {
        guard preservingOrder else {
            let enabled = Set(providers)
            return AgentProvider.allCases.filter { enabled.contains($0) }
        }
        var seen: Set<AgentProvider> = []
        return providers.filter { seen.insert($0).inserted }
    }
    public static func usesLegacyCodexDisplay(providers: [AgentProvider], snapshot: QuotaSnapshot?, style: Style) -> Bool {
        guard Set(providers) == [.codex], let primary = snapshot?.buckets.first(where: { $0.id == "codex" }),
              !primary.windows.contains(where: { $0.durationMinutes == 300 }) else { return false }
        if style == .split, primary.windows.contains(where: { $0.durationMinutes == 10080 }) { return false }
        return primary.windows.contains {
            $0.remainingPercent != nil || ($0.durationMinutes.map { $0 > 0 } ?? false) || $0.resetsAt != nil
        }
    }
    /// One quota section's drawing. A lone service shows its details beside
    /// the ring unless `details` is off; then its ring stands alone as in a row.
    public static func layout(providers: [AgentProvider], snapshots: [AgentProvider: QuotaSnapshot], style: Style, now: Date,
                              preservingOrder: Bool = false, details: Bool = true,
                              periods: (AgentProvider) -> ExpandedPanelOptions.Periods = { _ in .both }) -> Layout {
        let ordered = order(providers, preservingOrder: preservingOrder)
        if usesLegacyCodexDisplay(providers: ordered, snapshot: snapshots[.codex], style: style) { return Layout(kind: .legacyCodex, slots: []) }
        if ordered == [.deepseek] { return Layout(kind: .deepseekSolo, slots: []) }
        let drawn = Self.slots(providers: ordered, style: style, preservingOrder: preservingOrder, periods: periods)
        if style == .classic { return Layout(kind: .classicRings, slots: drawn) }
        let single = details && ordered.count == 1 && ordered.first.map {
            Reading(provider: $0, period: .weekly, snapshot: snapshots[$0], now: now).availability != .unavailable
        } == true
        return Layout(kind: single ? .splitSingle : .splitRings, slots: drawn)
    }

    public struct Reading: Codable, Equatable, Sendable {
        public typealias Availability = QuotaDashboardPresentation.Availability
        public let provider: AgentProvider
        public let period: Period
        public let window: QuotaWindow?
        private let date: Date
        private let extraHelp: String?
        public let availability: Availability
        public let windowID: String?
        public let durationMinutes: Int?
        public let resetsAt: Double?
        public let capturedAt: Double?
        public let bucketName: String?
        public let remainingPercent: Double?
        public let remainingTimePercent: Double?
        public let pacePercent: Double?
        public let paceText: String
        public let valueText: String
        public let timeText: String
        public let countdown: String
        public let resetDate: String
        public let resetMoment: String?
        public let resetAtText: String
        public let freshnessText: String
        public let sourceText: String?
        public let verdict: Verdict?
        public let verdictText: String?
        public let pressing: Bool
        public let projectionText: String?
        public let projectionInline: String?
        public let projectionWarns: Bool
        public let projectionEarly: Bool
        public let otherPeriodText: String?
        public let splitHelp: String
        public let classicHelp: String
        public let accessibilityLabel: String
        public let classicAccessibilityLabel: String

        public init(provider: AgentProvider, period: Period, snapshot: QuotaSnapshot?, failed: Bool = false,
                    refreshing: Bool = false, sourceText: String? = nil, extraHelp: String? = nil, now: Date) {
            let bucket = QuotaDashboardPresentation.bucket(provider: provider, snapshot: snapshot)
            let window = bucket?.windows.first { $0.durationMinutes == period.minutes }
            let expired = window?.resetsAt.map { $0 <= now } == true
            let stale = snapshot?.isStale(at: now) == true || expired || failed
            let availability: Availability
            if snapshot == nil || bucket == nil { availability = .unavailable }
            else if stale { availability = .stale }
            else if window != nil { availability = .available }
            else if period == .fiveHour, bucket?.id == provider.rawValue,
                    let weekly = bucket?.windows.first(where: { $0.durationMinutes == 10080 }),
                    weekly.remainingPercent != nil, weekly.resetsAt.map({ $0 > now }) == true,
                    bucket?.windows.allSatisfy({ $0.durationMinutes == 10080 }) == true { availability = .proOnly }
            else { availability = .missingPeriod }
            let freshness = QuotaDashboardPresentation.freshness(snapshot: snapshot, window: window, failed: failed, refreshing: refreshing, now: now)
            self.init(provider: provider, period: period, window: window, availability: availability,
                remainingQuotaPercent: window?.remainingPercent, remainingTimePercent: window?.remainingTimePercent(at: now),
                capturedAt: snapshot?.capturedAt, freshnessText: freshness, sourceText: sourceText,
                bucketName: bucket.flatMap { $0.id == provider.rawValue ? nil : $0.name ?? $0.id }, extraHelp: extraHelp, now: now)
        }

        /// Typed readings also support independent unknown quota/time values.
        public init(provider: AgentProvider, period: Period, window: QuotaWindow?, availability: Availability,
                    remainingQuotaPercent: Double?, remainingTimePercent: Double?, capturedAt: Date?,
                    freshnessText: String, sourceText: String?, bucketName: String?, extraHelp: String? = nil,
                    now: Date = Date()) {
            self.provider = provider; self.period = period; self.window = window; self.date = now; self.extraHelp = extraHelp; self.availability = availability
            windowID = window?.id; durationMinutes = window?.durationMinutes
            resetsAt = window?.resetsAt?.timeIntervalSince1970; self.capturedAt = capturedAt?.timeIntervalSince1970
            self.bucketName = bucketName; remainingPercent = remainingQuotaPercent
            self.remainingTimePercent = remainingTimePercent; self.freshnessText = freshnessText
            pacePercent = availability == .available ? window?.pacePercent(at: now) : nil
            paceText = pacePercent.map { "\(Int($0.rounded()))%" } ?? "—"
            verdict = pacePercent.map(Verdict.init(pace:))
            verdictText = verdict?.label
            pressing = availability == .available && (remainingPercent.map { $0.isFinite && $0 <= 15 } == true || verdict == .fast)
            valueText = Self.percent(remainingPercent).replacingOccurrences(of: "%", with: "")
            timeText = Self.percent(remainingTimePercent)
            countdown = window?.remainingSeconds(at: now).map { $0 <= 0 ? L10n.text("dashboard.countdown_waiting") : Self.duration($0) } ?? "—"
            resetDate = window?.resetsAt.map { L10n.text("quota.reset_date", L10n.date($0)) } ?? L10n.text("quota.reset_unknown")
            resetMoment = window?.resetsAt.map { L10n.moment($0, relativeTo: now) }
            resetAtText = resetMoment.map { L10n.text("dashboard.reset_at", $0) } ?? L10n.text("quota.reset_unknown")
            self.sourceText = sourceText
            let projection = availability == .available ? window?.projection(at: now) : nil
            projectionText = Self.projection(projection, inline: false); projectionInline = Self.projection(projection, inline: true)
            if case .runsOut = projection { projectionWarns = true } else { projectionWarns = false }
            if case .tooEarly = projection { projectionEarly = true } else { projectionEarly = false }
            if [.available, .stale].contains(availability), let remainingPercent, remainingPercent.isFinite {
                otherPeriodText = [period.rawValue + " " + Self.percent(remainingPercent), window?.remainingSeconds(at: now).map {
                    $0 <= 0 ? L10n.text("dashboard.countdown_waiting") : Self.duration($0)
                }].compactMap { $0 }.joined(separator: " · ")
            } else { otherPeriodText = nil }
            var details = [L10n.text("dashboard.rings_help")]
            if let bucketName { details.append(bucketName) }
            if availability == .missingPeriod { details.append(L10n.text("dashboard.period_unavailable", period.accessibilityLabel)) }
            details += [L10n.text("dashboard.time_remaining", timeText), resetDate]
            splitHelp = (details + [verdictText, freshnessText].compactMap { $0 }).joined(separator: "\n")
            let proOnly = availability == .proOnly
            var classicDetails = [L10n.text(proOnly ? "dashboard.pro_help" : "dashboard.rings_help")]
            if let bucketName { classicDetails.append(bucketName) }
            if availability == .missingPeriod { classicDetails.append(L10n.text("dashboard.period_unavailable", period.accessibilityLabel)) }
            if !proOnly { classicDetails += [L10n.text("dashboard.time_remaining", timeText), resetDate] }
            classicHelp = (classicDetails + [sourceText, freshnessText, extraHelp].compactMap { $0 }).joined(separator: "\n")
            let name = bucketName.map { provider.displayName + " " + $0 } ?? provider.displayName
            let summary = [resetDate, verdictText, freshnessText].compactMap { $0 }.joined(separator: ". ")
            accessibilityLabel = L10n.text("dashboard.rings_accessibility", name, period.accessibilityLabel,
                remainingPercent?.isFinite != true ? L10n.text("common.unknown") : Self.percent(remainingPercent),
                remainingTimePercent?.isFinite != true ? L10n.text("common.unknown") : Self.percent(remainingTimePercent), summary)
            classicAccessibilityLabel = proOnly ? name + ", " + period.accessibilityLabel + ". " + L10n.text("dashboard.pro_help") : accessibilityLabel
        }
        public var remainingQuotaPercent: Double? { remainingPercent }
        public var fraction: Double? { remainingPercent.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil } }
        public var timeFraction: Double? { remainingTimePercent.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil } }
        public var projection: QuotaProjection? { availability == .available ? window?.projection(at: readingDate) : nil }
        private var readingDate: Date { date }
        public func at(_ now: Date) -> Self {
            guard now != date else { return self }
            return Self(provider: provider, period: period, window: window, availability: availability,
                remainingQuotaPercent: remainingPercent, remainingTimePercent: remainingTimePercent,
                capturedAt: capturedAt.map(Date.init(timeIntervalSince1970:)), freshnessText: freshnessText,
                sourceText: sourceText, bucketName: bucketName, extraHelp: extraHelp, now: now)
        }

        public func classicHelp(providerHelp: String) -> String {
            let proOnly = availability == .proOnly
            var details = [L10n.text(proOnly ? "dashboard.pro_help" : "dashboard.rings_help")]
            if let bucketName { details.append(bucketName) }
            if availability == .missingPeriod { details.append(L10n.text("dashboard.period_unavailable", period.accessibilityLabel)) }
            if !proOnly { details += [L10n.text("dashboard.time_remaining", Self.percent(remainingTimePercent)), resetDate] }
            details.append(providerHelp)
            return details.joined(separator: "\n")
        }
        private static func percent(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "—" }
            return "\(Int(min(100, max(0, value)).rounded()))%"
        }
        private static func duration(_ seconds: TimeInterval) -> String {
            guard seconds >= 60 else { return L10n.text("dashboard.countdown_soon") }
            let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
            if days > 0 { return L10n.text("dashboard.countdown_days", days, hours) }
            if hours > 0 { return L10n.text("dashboard.countdown_hours", hours, minutes) }
            return L10n.text("dashboard.countdown_minutes", minutes)
        }
        private static func projection(_ value: QuotaProjection?, inline: Bool) -> String? {
            switch value {
            case nil: return nil
            case .tooEarly: return L10n.text("dashboard.projection_early")
            case .remainingAtReset(let left): return L10n.text(inline ? "dashboard.projection_left_inline" : "dashboard.projection_left", "\(Int(left.rounded()))%")
            case .runsOut(let seconds):
                return seconds <= 0 ? L10n.text("dashboard.projection_used_up") : L10n.text(inline ? "dashboard.projection_out_inline" : "dashboard.projection_out", duration(seconds))
            }
        }
    }
}
