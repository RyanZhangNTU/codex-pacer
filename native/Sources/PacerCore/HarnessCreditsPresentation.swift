import Foundation

/// What a credits module shows, worded once in Core so the Mac and Windows
/// draw the same dial, lines and breakdown.
///
/// The ring is the month's credits, which refresh, so a fraction means
/// something there. Rewards and top-ups never refresh: they appear as an
/// amount in the ring's gap, never as a share of anything.
public struct HarnessCreditsPresentation: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable { case normal, warning, solid }

    public struct Dial: Codable, Equatable, Sendable {
        /// How full the ring is: what is left of the month's credits.
        public let fraction: Double?
        public let center: String
        /// Days to the refresh, or extra credits about to lapse.
        public let top: String?
        public let topWarns: Bool
        /// Extra credits in the gap; nil when there are none.
        public let badge: String?
        public let badgeTone: Tone
        /// "This month" in the gap when there are no extra credits.
        public let gapLabel: String?
        public let accessibilityLabel: String
    }

    public struct Line: Codable, Equatable, Sendable {
        public let label: String
        public let value: String
        public let detail: String?
        public let warns: Bool
    }

    public struct Row: Codable, Equatable, Sendable {
        public let kind: HarnessAccountCredits.Group.Kind
        public let name: String
        public let amount: String
        public let date: String?
        public let chip: String?
    }

    public struct Section: Codable, Equatable, Sendable {
        public let title: String
        public let rows: [Row]
    }

    public let dial: Dial
    public let plan: String?
    public let lines: [Line]
    public let sections: [Section]
    /// The collapsed bar's value, as the user chose it.
    public let barText: String

    public init?(credits: HarnessAccountCredits?, settings: HarnessCreditsSettings = .default, now: Date,
                 language: AppLanguage? = nil, calendar: Calendar = .current) {
        guard let reading = credits?.reading(at: now) else { return nil }
        let text = { (key: String, arguments: [CVarArg]) in L10n.text(key, arguments: arguments, language: language) }
        let locale = (language ?? L10n.language).locale
        func day(_ date: Date) -> String {
            var style = Date.FormatStyle().month(.abbreviated).day()
            style.calendar = calendar; style.timeZone = calendar.timeZone
            return date.formatted(style.locale(locale))
        }
        func days(_ date: Date) -> Int {
            max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0)
        }
        let monthly = reading.monthly, extra = reading.extra
        let soon = reading.expiringSoon(within: settings.expiryDays, at: now)

        func refresh(_ date: Date) -> String {
            switch days(date) {
            case 0: return text("credits.refresh_today", [])
            case 1: return text("credits.refresh_tomorrow", [])
            case let count: return text("credits.refresh_in_days", [count])
            }
        }
        func lapse(_ credits: Double, _ date: Date) -> String {
            let amount = Self.grouped(credits)
            switch days(date) {
            case 0: return text("credits.expiring_today", [amount])
            case 1: return text("credits.expiring_tomorrow", [amount])
            case let count: return text("credits.expiring_in_days", [amount, count])
            }
        }

        let center: String
        switch settings.center {
        case .monthlyPercent: center = reading.percent.map { "\(Int($0.rounded()))%" } ?? Self.grouped(reading.available)
        case .monthlyRemaining: center = Self.grouped(monthly?.remaining ?? reading.available)
        case .available: center = Self.grouped(reading.available)
        }
        let top = soon.map { lapse($0.credits, $0.date) } ?? monthly?.refreshesAt.map(refresh)
        let badgeTone: Tone = soon != nil ? .warning : (monthly.map { $0.remaining <= 0 } ?? false) ? .solid : .normal
        var spoken = [text("credits.spoken_monthly", [Self.grouped(monthly?.remaining ?? reading.available),
                                                      reading.percent.map { "\(Int($0.rounded()))%" } ?? "—"])]
        if let extra { spoken.append(text("credits.spoken_extra", [Self.grouped(extra.remaining)])) }
        if let top { spoken.append(top) }
        dial = Dial(fraction: reading.monthlyFraction, center: center, top: top, topWarns: soon != nil,
                    badge: extra.map { "+" + Self.badgeAmount($0.remaining) }, badgeTone: badgeTone,
                    gapLabel: extra == nil ? text("credits.this_month", []) : nil,
                    accessibilityLabel: spoken.joined(separator: text("credits.spoken_separator", [])))
        plan = reading.plan

        var lines: [Line] = []
        if let monthly {
            lines.append(Line(label: text("credits.monthly", []), value: Self.grouped(monthly.remaining) + " / " + Self.grouped(monthly.total),
                              detail: monthly.refreshesAt.map { text("credits.refreshes_on", [day($0)]) }, warns: false))
        }
        if let extra {
            let detail = soon.map { text("credits.extra_expiring", [Self.grouped($0.credits), day($0.date)]) }
                ?? extra.batches.first.map { text("credits.extra_earliest", [day($0.date)]) }
            lines.append(Line(label: text("credits.extra", []), value: text("credits.amount", [Self.grouped(extra.remaining)]),
                              detail: detail, warns: soon != nil))
        }
        lines.append(Line(label: text("credits.total", []), value: text("credits.available_amount", [Self.grouped(reading.available)]),
                          detail: nil, warns: false))
        self.lines = lines

        func row(_ group: Reading.GroupReading) -> Row? {
            guard group.remaining > 0.000001 || (group.total ?? 0) > 0.000001 else { return nil }
            let name = text("credits.group." + group.kind.rawValue, [])
            if group.kind.refreshes {
                return Row(kind: group.kind, name: name,
                           amount: Self.grouped(group.remaining) + (group.total.map { " / " + Self.grouped($0) } ?? ""),
                           date: group.refreshesAt.map { text("credits.refreshes_on", [day($0)]) }, chip: nil)
            }
            let lapsing = group.batches.first { $0.date > now && $0.date <= now.addingTimeInterval(TimeInterval(settings.expiryDays) * 86_400) }
            let chip = lapsing.map { days($0.date) == 0 ? text("credits.chip_today", []) : text("credits.chip_within", [settings.expiryDays]) }
            return Row(kind: group.kind, name: name, amount: Self.grouped(group.remaining),
                       date: group.expiresAt.map { text("credits.expires_on", [day($0)]) }, chip: chip)
        }
        let monthlyRows = reading.groups.filter(\.kind.refreshes).compactMap(row)
        let extraRows = reading.groups.filter { !$0.kind.refreshes }.compactMap(row)
        sections = [Section(title: text("credits.section.monthly", []), rows: monthlyRows),
                    Section(title: text("credits.section.extra", []), rows: extraRows)].filter { !$0.rows.isEmpty }
        barText = reading.compactFigure(settings.bar)
    }

    typealias Reading = HarnessAccountCredits.Reading

    /// 420.5 and 3,320 below a hundred thousand; 120k above it. Credits can be fractional.
    static func grouped(_ value: Double) -> String {
        let value = max(0, value)
        if value >= 100_000 { return HarnessAccountCredits.compactAmount(value) }
        if value < 1000, value.rounded() != value {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        let number = Int(value.rounded())
        var digits = String(number), result = ""
        while digits.count > 3 { result = "," + digits.suffix(3) + result; digits = String(digits.dropLast(3)) }
        return digits + result
    }

    /// +300, +1,300, +12k: short enough for the ring's gap.
    static func badgeAmount(_ value: Double) -> String { value >= 10_000 ? HarnessAccountCredits.compactAmount(value) : grouped(value) }
}
