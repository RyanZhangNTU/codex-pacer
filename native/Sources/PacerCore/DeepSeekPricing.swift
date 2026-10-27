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
/// Beijing are peak hours at twice the off-peak price. Public holidays are
/// off-peak, but Pacer has no holiday calendar and counts them as weekdays.
public enum DeepSeekPricing {
    struct Rate: Equatable { let cacheHit: Double; let cacheMiss: Double; let output: Double }
    static let offPeak: [String: Rate] = [
        "deepseek-flash": Rate(cacheHit: 0.02, cacheMiss: 1, output: 4),
        "deepseek-v4-pro": Rate(cacheHit: 0.15, cacheMiss: 4.5, output: 13.5)
    ]
    public static let beijing = TimeZone(identifier: "Asia/Shanghai")!
    private static let peakHours: [Range<Int>] = [9..<12, 14..<18]

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
        guard let weekday = parts.weekday, let hour = parts.hour, (2...6).contains(weekday) else { return false }
        return peakHours.contains { $0.contains(hour) }
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
