import Foundation

/// The original cycle readings and localized labels, without account or
/// credit identifiers. Marker grouping uses the native chart's point widths.
public struct QuotaCycleChartPresentation: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let timestamp: Double
        public let fraction: Double
        public let remaining: Double
        public let dateText: String
        public let valueText: String
        public let accessibilityLabel: String
    }
    public struct Expiry: Codable, Equatable, Sendable {
        public let timestamp: Double
        public let fraction: Double
        public let count: Int
        public let dateText: String
        public let countText: String
        public let accessibilityLabel: String
    }
    public struct Marker: Codable, Equatable, Sendable {
        public let id: Double
        public let x: Double
        public let dateX: Double
        public let width: Double
        public let count: Int
        public let countText: String?
        public let title: String
        public let details: [Expiry]
        public let moreText: String?
        public let accessibilityLabel: String
    }
    public let language: String
    public let startedAt: Double
    public let resetsAt: Double
    public let startText: String
    public let endText: String
    public let points: [Point]
    public let expiries: [Expiry]
    public let hasPartialExpiryDetails: Bool
    public let accessibilityLabel: String
    public let lineHelp: String

    public init(data: QuotaChartData, language: AppLanguage = L10n.language) {
        self.language = language.rawValue
        startedAt = data.startedAt.timeIntervalSince1970; resetsAt = data.resetsAt.timeIntervalSince1970
        let span = data.resetsAt.timeIntervalSince(data.startedAt)
        let short = Date.FormatStyle.dateTime.month(.defaultDigits).day(.defaultDigits).locale(language.locale)
        let detail = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().locale(language.locale)
        let spoken = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        startText = data.startedAt.formatted(short); endText = data.resetsAt.formatted(short)
        points = data.points.map { point in
            let date = point.timestamp.formatted(detail), value = "\(Int(point.remaining.rounded()))%"
            return Point(timestamp: point.timestamp.timeIntervalSince1970,
                fraction: span > 0 ? point.timestamp.timeIntervalSince(data.startedAt) / span : 0,
                remaining: point.remaining, dateText: date, valueText: value,
                accessibilityLabel: [date, value].joined(separator: ", "))
        }
        expiries = data.expiries.map { expiry in
            Expiry(timestamp: expiry.date.timeIntervalSince1970,
                fraction: span > 0 ? expiry.date.timeIntervalSince(data.startedAt) / span : 0,
                count: expiry.count, dateText: expiry.date.formatted(detail),
                countText: L10n.text("chart.expiry_count", expiry.count, language: language),
                accessibilityLabel: L10n.text("chart.expiry_item", expiry.count, expiry.date.formatted(spoken), language: language))
        }
        hasPartialExpiryDetails = data.hasPartialExpiryDetails
        accessibilityLabel = L10n.text("chart.accessibility", points.count, language: language)
        lineHelp = L10n.text("chart.line_help", language: language)
    }

    /// Plot-local coordinates. The chart range keeps four points at each end;
    /// nearby deadlines merge before their capsules would overlap.
    public func markers(plotWidth: Double) -> [Marker] {
        guard plotWidth.isFinite, plotWidth >= 43 else { return [] }
        func position(_ expiry: Expiry) -> Double { 4 + expiry.fraction * (plotWidth - 8) }
        var groups: [[Expiry]] = []
        for expiry in expiries {
            if let last = groups.last, let first = last.first, position(expiry) - position(first) < 40 {
                groups[groups.count - 1].append(expiry)
            } else { groups.append([expiry]) }
        }
        let selected = AppLanguage(rawValue: language) ?? L10n.language
        func marker(_ group: [Expiry]) -> Marker {
            let first = group[0], count = group.reduce(0) { $0 + $1.count }, width = count > 1 ? 43.0 : 28.0
            return Marker(id: first.timestamp, x: min(plotWidth - width / 2, max(width / 2, position(first))),
                dateX: position(first), width: width, count: count, countText: count > 1 ? String(count) : nil,
                title: L10n.text(hasPartialExpiryDetails ? "chart.known_expiring" : "chart.expiring", count, language: selected),
                details: Array(group.prefix(3)), moreText: group.count > 3 ? L10n.text("chart.more_expiries", group.count - 3, language: selected) : nil,
                accessibilityLabel: L10n.text("chart.expiry_summary", count,
                    group.map(\.accessibilityLabel).joined(separator: L10n.text("chart.detail_separator", language: selected)), language: selected))
        }
        var result: [(values: [Expiry], marker: Marker)] = []
        for group in groups {
            var values = group, current = marker(group)
            while let last = result.last, current.x - last.marker.x < (current.width + last.marker.width) / 2 + 6 {
                result.removeLast(); values = last.values + values; current = marker(values)
            }
            result.append((values, current))
        }
        return result.map(\.marker)
    }
}
