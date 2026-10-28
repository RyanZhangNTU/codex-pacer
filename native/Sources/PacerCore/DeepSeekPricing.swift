import Foundation

/// Token counts from one DeepSeek response. `input` excludes cache reads.
public struct DeepSeekUsage: Equatable, Sendable {
    public let input: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let output: Int
    public init?(input: Int, cacheRead: Int, cacheWrite: Int = 0, output: Int) {
        let limit = 1 << 32
        guard [input, cacheRead, cacheWrite, output].allSatisfy({ (0..<limit).contains($0) }) else { return nil }
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
    }
}

/// The published CNY price list (2026-10-27). Weekday 09–12 and 14–18 in
/// Beijing are peak hours at twice the off-peak price. Weekends and public
/// holidays are off-peak; the calendar covers 2026, and make-up working days
/// on weekends are treated as weekends, so peak hours are an estimate.
public enum DeepSeekPricing {
    struct Rate: Equatable { let cacheHit: Double; let cacheMiss: Double; let output: Double }
    static let offPeak: [String: Rate] = [
        "deepseek-flash": Rate(cacheHit: 0.02, cacheMiss: 1, output: 4),
        "deepseek-v4-pro": Rate(cacheHit: 0.15, cacheMiss: 4.5, output: 13.5)
    ]
    public static let beijing = TimeZone(identifier: "Asia/Shanghai")!
    private static let peakHours: [Range<Int>] = [9..<12, 14..<18]
    /// Weekday public holidays in the State Council's 2026 schedule (Beijing dates).
    static let holidays: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23",
        "2026-04-06", "2026-05-01", "2026-05-04", "2026-05-05", "2026-06-19", "2026-09-25",
        "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07"
    ]
    /// The last Beijing year whose holidays are known.
    public static let calendarYear = 2026
    /// Search and fetch tool calls cost ¥5 per 1,000 from 2026-11-01 in Beijing.
    public static let searchCallPrice = 0.005
    static let searchBillingStart = Date(timeIntervalSince1970: 1_793_462_400)
    static let searchTools: Set<String> = ["web_search", "web_fetch", "search", "fetch"]
    /// Harness's own DeepSeek providers; third-party channels bill differently and get no estimate.
    static let officialProviders: Set<String> = ["deepseek", "deepseek-account", "deepseek-official", "deepseek-api-key"]
    public static func isOfficial(provider: String?) -> Bool { provider.map { officialProviders.contains($0.lowercased()) } ?? true }
    /// The price of one search or fetch call, or nil for other tools and before billing starts.
    public static func toolCost(_ name: String, at date: Date) -> Double? {
        searchTools.contains(name.lowercased()) && date >= searchBillingStart ? searchCallPrice : nil
    }

    public static func knowsModel(_ model: String?) -> Bool { model.map { rate(for: $0) != nil } ?? false }
    static func rate(for model: String) -> Rate? {
        let name = model.lowercased()
        if let exact = offPeak[name] { return exact }
        // Dated or suffixed aliases keep their family's price.
        return offPeak.first { name.hasPrefix($0.key + "-") }?.value
    }

    /// Estimated cost in CNY, or nil for a model without a known price.
    public static func cost(model: String?, usage: DeepSeekUsage, at date: Date) -> Double? {
        guard let model, let rate = rate(for: model) else { return nil }
        let multiplier = isPeak(at: date) ? 2.0 : 1.0
        let missed = Double(usage.input + usage.cacheWrite), hit = Double(usage.cacheRead), output = Double(usage.output)
        return (missed * rate.cacheMiss + hit * rate.cacheHit + output * rate.output) * multiplier / 1_000_000
    }

    public static func isPeak(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = beijing
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, (2...6).contains(weekday),
              peakHours.contains(where: { $0.contains(hour) }) else { return false }
        return !isHoliday(date, calendar: calendar)
    }
    static func isHoliday(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, let month = day.month, let value = day.day else { return false }
        return holidays.contains(String(format: "%04d-%02d-%02d", year, month, value))
    }

    /// The next instant the price multiplier changes, at most eight days ahead.
    public static func nextChange(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = beijing
        let current = isPeak(at: date)
        guard var hour = calendar.dateInterval(of: .hour, for: date)?.end else { return nil }
        for _ in 0..<(24 * 8) {
            if isPeak(at: hour) != current { return hour }
            hour = hour.addingTimeInterval(3600)
        }
        return nil
    }

    /// Peak spans that overlap a local day, for drawing the day dial's bezel.
    public static func peakIntervals(overlapping day: DateInterval) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = beijing
        var result: [DateInterval] = []
        guard var start = calendar.dateInterval(of: .hour, for: day.start)?.start else { return [] }
        var open: Date?
        while start < day.end {
            if isPeak(at: start) { open = open ?? max(start, day.start) }
            else if let begin = open { result.append(DateInterval(start: begin, end: start)); open = nil }
            start = start.addingTimeInterval(3600)
        }
        if let begin = open { result.append(DateInterval(start: begin, end: day.end)) }
        return result
    }
}
