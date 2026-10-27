import Foundation

/// What the day dial and its details show: the platform balance, the local
/// spend estimate for today and the week, and whether the price is doubled.
public struct DeepSeekWallet: Equatable, Sendable {
    public enum State: Equatable, Sendable { case normal, low, exhausted, stale, disconnected }
    public let balance: DeepSeekBalance?
    public let state: State
    public let today: Double
    public let todayPeak: Double
    /// Spend in each local hour of today.
    public let hourly: [Double]
    /// Average spend by this time on the previous seven days.
    public let typicalByNow: Double?
    public let averageDaily: Double?
    public let days: [DeepSeekSpendLedger.Day]
    public let peakNow: Bool
    public let nextPriceChange: Date?
    public let peakToday: [DateInterval]
    public let day: DateInterval

    public init(balance: DeepSeekBalance?, connected: Bool, ledger: DeepSeekSpendLedger, now: Date,
                lowThreshold: Double = 10, calendar: Calendar = .current) {
        self.balance = balance
        let day = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
        self.day = day
        let spent = ledger.total(in: DateInterval(start: day.start, end: max(day.start, now)))
        today = spent.total; todayPeak = spent.peak
        hourly = ledger.hourly(on: now, calendar: calendar)
        typicalByNow = ledger.typicalByThisTime(now, calendar: calendar)
        averageDaily = ledger.averageDaily(endingAt: now, calendar: calendar)
        days = ledger.days(7, endingAt: now, calendar: calendar)
        peakNow = DeepSeekPricing.isPeak(at: now)
        nextPriceChange = DeepSeekPricing.nextChange(after: now)
        peakToday = DeepSeekPricing.peakIntervals(overlapping: day)
        if let balance {
            if balance.isStale(at: now) { state = .stale }
            else if balance.isExhausted { state = .exhausted }
            else {
                let runway = averageDaily.flatMap { $0 > 0 ? balance.total / $0 : nil }
                state = balance.total < (balance.alertBound ?? lowThreshold) || (runway.map { $0 < 3 } ?? false) ? .low : .normal
            }
        } else { state = connected ? .stale : .disconnected }
    }

    /// Days the balance lasts at the recent daily average.
    public var runwayDays: Double? {
        guard let balance, let averageDaily, averageDaily > 0 else { return nil }
        return balance.total / averageDaily
    }
    /// Today runs noticeably ahead of a usual day by this hour.
    public var spendingFast: Bool {
        guard let typicalByNow, typicalByNow > 0.01 else { return false }
        return today > typicalByNow / 0.85
    }

    /// `¥8.40`, `¥86`, `¥1.2k`: two decimals under ten yuan.
    public static func compactAmount(_ value: Double) -> String {
        guard value.isFinite else { return "¥–" }
        if value < 10 { return String(format: "¥%.2f", max(0, value)) }
        if value < 1000 { return "¥" + String(Int(value.rounded(.down))) }
        return String(format: "¥%.1fk", value / 1000)
    }
    /// Spend rounds to the nearest yuan from ten up, where a balance rounds down.
    public static func compactSpend(_ value: Double) -> String {
        guard value.isFinite else { return "¥–" }
        return value < 9.995 || value >= 999.5 ? compactAmount(value) : "¥" + String(Int(value.rounded()))
    }
    /// A turn's estimate: `≈¥0.42`, or `<¥0.01` for less than a fen.
    public static func turnAmount(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        if value < 0.01 { return "<¥0.01" }
        return value < 10 ? String(format: "≈¥%.2f", value) : String(format: "≈¥%.1f", value)
    }
}
