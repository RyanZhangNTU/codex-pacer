import Foundation

/// A daily or weekly spending limit. Pacer only reminds; it never blocks requests.
public struct DeepSeekBudgetPeriod: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case day, week }
    public let kind: Kind
    public let limit: Double
    public let spent: Double
    /// Today, or the week from Monday 00:00 local time.
    public let interval: DateInterval
    public var remaining: Double { limit - spent }
    public var usedFraction: Double { limit > 0 ? spent / limit : 1 }
    public var exceeded: Bool { spent >= limit - 0.000_5 }
    /// The reminder line: 80% of the limit.
    public var nearing: Bool { usedFraction >= 0.8 }
    /// The period as a quota window, so pace and projection follow the quota rings.
    public var window: QuotaWindow {
        QuotaWindow(id: "deepseek-" + kind.rawValue, usedPercent: min(100, max(0, usedFraction * 100)),
            durationMinutes: max(1, Int((interval.duration / 60).rounded())), resetsAt: interval.end)
    }
}

/// Spending limits from Settings; nil or zero turns one off.
public struct DeepSeekBudgets: Equatable, Sendable {
    public var daily: Double?
    public var weekly: Double?
    public init(daily: Double? = nil, weekly: Double? = nil) {
        self.daily = daily.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.weekly = weekly.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
    public var isEmpty: Bool { daily == nil && weekly == nil }

    /// What switching to budgets fills in: the recent daily average with a
    /// fifth more room, rounded up to ¥5 a day and ¥10 a week; ¥10 and ¥50
    /// before there is any spend.
    public static func suggested(averageDaily: Double?) -> Self {
        guard let average = averageDaily, average.isFinite, average >= 0.01 else { return Self(daily: 10, weekly: 50) }
        func up(_ value: Double, to step: Double) -> Double { max(step, (value / step - 1e-9).rounded(.up) * step) }
        return Self(daily: up(average * 1.2, to: 5), weekly: up(average * 7 * 1.2, to: 10))
    }
}

/// What speed and the spend-spike line count: this Mac's estimate, updated with
/// every response, or the account's charges from balance readings, which include
/// other devices and server-side tools but update about once a minute.
public enum DeepSeekSpeedSource: String, CaseIterable, Sendable { case local, account }

/// The one collapsed alert DeepSeek shows, most urgent first. Solid means act
/// now, outlined means take note; the capsule keeps DeepSeek's color.
public enum DeepSeekAlert: Equatable, Sendable {
    case exhausted, spike, overBudget(DeepSeekBudgetPeriod.Kind), lowBalance, nearingBudget(DeepSeekBudgetPeriod.Kind)
    public var solid: Bool {
        switch self {
        case .exhausted, .spike, .overBudget: true
        case .lowBalance, .nearingBudget: false
        }
    }
}

/// What the dials and their details show: the platform balance, the local
/// estimate and what the account was charged beyond it, budgets and pace.
public struct DeepSeekWallet: Equatable, Sendable {
    public enum State: Equatable, Sendable { case normal, low, exhausted, stale, disconnected }
    public let balance: DeepSeekBalance?
    public let state: State
    /// Today's local estimate from this Mac's session logs.
    public let today: Double
    public let todayPeak: Double
    /// Charged to the account today beyond the local estimate (not on this Mac).
    public let elsewhereToday: Double
    /// Spend in each local hour of today.
    public let hourly: [Double]
    /// Average spend by this time on the previous seven days.
    public let typicalByNow: Double?
    public let averageDaily: Double?
    public let days: [DeepSeekSpendLedger.Day]
    /// Each of `days` with spend not on this Mac added, where the account saw that day.
    public let dayTotals: [Double]
    /// Today's tasks by spend, sub-agents included in their root task.
    public let tasks: [DeepSeekSpendLedger.TaskSpend]
    /// Spend in each of the last twelve 10-minute spans, oldest first, from the chosen source.
    public let speed: [Double]
    public let speedSource: DeepSeekSpeedSource
    /// Spend over the last ten minutes: the newest span.
    public let recentSpend: Double
    /// The set spike line, or the automatic one.
    public let spikeLimit: Double
    /// The set low-balance line, or the platform's alert line, or ¥10.
    public let lowLine: Double
    public let daily: DeepSeekBudgetPeriod?
    public let weekly: DeepSeekBudgetPeriod?
    public let peakNow: Bool
    public let nextPriceChange: Date?
    public let peakToday: [DateInterval]
    public let day: DateInterval

    public init(balance: DeepSeekBalance?, connected: Bool, ledger: DeepSeekSpendLedger, now: Date,
                lowLine: Double? = nil, history: DeepSeekBalanceHistory = DeepSeekBalanceHistory(),
                budgets: DeepSeekBudgets = DeepSeekBudgets(), spikeLimit: Double? = nil, speedSource: DeepSeekSpeedSource = .local,
                calendar: Calendar = .current) {
        self.balance = balance
        let day = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
        self.day = day
        let spent = ledger.total(in: DateInterval(start: day.start, end: max(day.start, now)))
        today = spent.total; todayPeak = spent.peak
        hourly = ledger.hourly(on: now, calendar: calendar)
        typicalByNow = ledger.typicalByThisTime(now, calendar: calendar)
        averageDaily = ledger.averageDaily(endingAt: now, calendar: calendar)
        days = ledger.days(7, endingAt: now, calendar: calendar)
        // The account is compared with the local estimate over the same span:
        // from the first reading (or midnight) to the latest reading.
        func elsewhere(_ start: Date) -> Double {
            guard let interval = calendar.dateInterval(of: .day, for: start), let seen = history.coverage(of: interval) else { return 0 }
            return max(0, history.charged(onDayStarting: interval.start) - ledger.total(in: seen).total)
        }
        elsewhereToday = elsewhere(day.start)
        dayTotals = days.map { $0.total + elsewhere($0.start) }
        tasks = ledger.tasks(in: DateInterval(start: day.start, end: max(day.start, now)))
        speed = speedSource == .account ? history.spent(12, of: 600, endingAt: now) : ledger.recent(12, of: 600, endingAt: now)
        self.speedSource = speedSource
        recentSpend = speed.last ?? 0
        self.spikeLimit = spikeLimit ?? ledger.automaticSpikeLimit(before: day.start)
        let lowLine = lowLine ?? Self.automaticLowLine(balance)
        self.lowLine = lowLine
        let todayTotal = today + elsewhereToday
        daily = budgets.daily.map { DeepSeekBudgetPeriod(kind: .day, limit: $0, spent: todayTotal, interval: day) }
        var weekCalendar = calendar; weekCalendar.firstWeekday = 2
        if let limit = budgets.weekly, let week = weekCalendar.dateInterval(of: .weekOfYear, for: now) {
            let total = zip(days, dayTotals).filter { $0.0.start >= week.start && $0.0.start < day.start }.reduce(0) { $0 + $1.1 }
            weekly = DeepSeekBudgetPeriod(kind: .week, limit: limit, spent: total + todayTotal, interval: week)
        } else { weekly = nil }
        peakNow = DeepSeekPricing.isPeak(at: now)
        nextPriceChange = DeepSeekPricing.nextChange(after: now)
        peakToday = DeepSeekPricing.peakIntervals(overlapping: day)
        if let balance {
            if balance.isStale(at: now) { state = .stale }
            else if balance.isExhausted { state = .exhausted }
            else { state = balance.total < lowLine ? .low : .normal }
        } else { state = connected ? .stale : .disconnected }
    }

    public static let defaultLowLine = 10.0
    public static let minimumSpikeLimit = 5.0
    /// The low-balance line when none is set: the platform's alert line, or ¥10.
    public static func automaticLowLine(_ balance: DeepSeekBalance?) -> Double { balance?.alertBound ?? defaultLowLine }

    /// Today's spend wherever it happened: the local estimate plus what the
    /// account was charged beyond it.
    public var todayTotal: Double { today + elsewhereToday }
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
    /// Ten minutes cost more than the reminder line.
    public var spiking: Bool { spikeLimit > 0 && recentSpend >= spikeLimit }
    /// Spend per minute over the last ten minutes.
    public var ratePerMinute: Double { recentSpend / 10 }
    public func budget(_ kind: DeepSeekBudgetPeriod.Kind) -> DeepSeekBudgetPeriod? { kind == .day ? daily : weekly }
    /// The preferred period's budget, or the other one when only that is set.
    public func ringBudget(prefer kind: DeepSeekBudgetPeriod.Kind) -> DeepSeekBudgetPeriod? {
        budget(kind) ?? budget(kind == .day ? .week : .day)
    }

    /// The most urgent alert among the enabled kinds; an empty wallet always shows.
    public func alert(lowBalance: Bool, spike: Bool, budget: Bool) -> DeepSeekAlert? {
        if state == .exhausted { return .exhausted }
        if spike, spiking { return .spike }
        if budget, let period = [daily, weekly].compactMap({ $0 }).first(where: \.exceeded) { return .overBudget(period.kind) }
        if lowBalance, state == .low { return .lowBalance }
        if budget, let period = [daily, weekly].compactMap({ $0 }).first(where: \.nearing) { return .nearingBudget(period.kind) }
        return nil
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
    /// A budget's remainder in the collapsed bar: `¥4.1`, `¥64`, `−¥3.2` once over.
    public static func compactRemaining(_ value: Double) -> String {
        guard value.isFinite else { return "¥–" }
        let amount = abs(value), sign = value < -0.05 ? "−" : ""
        if amount < 10 { return sign + String(format: "¥%.1f", amount) }
        return sign + (amount < 1000 ? "¥" + String(Int(amount.rounded(.down))) : String(format: "¥%.1fk", amount / 1000))
    }
    /// A turn's estimate: `≈¥0.42`, or `<¥0.01` for less than a fen.
    public static func turnAmount(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        if value < 0.01 { return "<¥0.01" }
        return value < 10 ? String(format: "≈¥%.2f", value) : String(format: "≈¥%.1f", value)
    }
}
