import Foundation

/// A complete, optional protocol-1 settings group. Omitting the group retains
/// it; null daily/weekly amounts inside an update explicitly turn them off.
struct EngineDeepSeekSettings: Codable, Equatable, Sendable {
    var mode = "balance"
    var daily: Double?
    var weekly: Double?
    var ringPeriod = "day"
    var speedSource = "local"
    var showsTurnCost = true
    var balanceSource: String?
    var selection: DeepSeekBalanceSelection { balanceSource.flatMap(DeepSeekBalanceSelection.init(rawValue:)) ?? .automatic }

    var isValid: Bool {
        ["balance", "budget"].contains(mode) && ["day", "week"].contains(ringPeriod) && ["local", "account"].contains(speedSource)
            && (balanceSource == nil || DeepSeekBalanceSelection(rawValue: balanceSource!) != nil)
            && [daily, weekly].compactMap { $0 }.allSatisfy { $0.isFinite && $0 > 0 }
    }
    var budgets: DeepSeekBudgets { mode == "budget" ? .init(daily: daily, weekly: weekly) : .init() }
}

struct EngineDeepSeekConnection: Codable, Equatable {
    let context: String, source: String
    let mode: String?
    let hasKey: Bool, refreshing: Bool, webAvailable: Bool
    let reading: DeepSeekConnectionPresentation
    let status: DeepSeekBalanceStatusPresentation?
    init(_ state: DeepSeekBalanceState, now: Date) {
        context = state.token; source = state.source.rawValue; mode = state.mode?.rawValue
        hasKey = state.hasKey; refreshing = state.refreshing; webAvailable = state.webAvailable
        reading = .init(source: state.source, detected: state.detected, balance: state.balance,
            error: state.error, refreshing: state.refreshing, now: now)
        status = .init(error: state.error, refreshing: state.refreshing)
    }
}

/// Formatted settings readings and default amounts use the same Core rules
/// as the Mac page. No task names, account identifiers or paths are included.
struct EngineDeepSeekSettingsReading: Codable, Equatable {
    let suggestedDaily: Double
    let suggestedWeekly: Double
    let dailyReference: String?
    let weeklyReference: String?
    let balanceText: String?
    let runwayText: String?
    let connectionText: String
    let pricingSpans: [EngineWallet.Span]
    let compactBudgetKind: String?
    let compactBudgetPercent: Double?
    let compactBudgetDimmed: Bool

    init(wallet: DeepSeekWallet, compactBudget: DeepSeekBudgetPeriod?, freshness: String, now: Date) {
        let average = wallet.averageDaily.flatMap { $0 >= 0.01 ? $0 : nil }
        let suggestion = DeepSeekBudgets.suggested(averageDaily: average)
        suggestedDaily = suggestion.daily!; suggestedWeekly = suggestion.weekly!
        dailyReference = average.map { L10n.text("deepseek.budget.average_day", DeepSeekWallet.compactSpend($0)) }
        weeklyReference = average.map { L10n.text("deepseek.budget.average_week", DeepSeekWallet.compactSpend($0 * 7)) }
        balanceText = wallet.balance.map { DeepSeekDialPresentation.amount($0.total) }
        connectionText = wallet.balance == nil ? L10n.text("deepseek.signed_out") : L10n.text("deepseek.connected", freshness)
        runwayText = wallet.runwayDays.map { $0 >= 365 ? L10n.text("deepseek.runway_year") : L10n.text("deepseek.runway_short", max(1, Int($0.rounded(.down)))) }
        compactBudgetKind = compactBudget?.kind.rawValue
        compactBudgetPercent = compactBudget.map { max(0, $0.remaining) / $0.limit * 100 }
        compactBudgetDimmed = [.stale, .disconnected].contains(wallet.state)
        let calendar = Calendar.current
        var spans: [EngineWallet.Span] = []
        for offset in 0..<10 {
            guard let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let day = calendar.dateInterval(of: .day, for: start), day.duration > 0 else { continue }
            let peaks = DeepSeekPricing.peakIntervals(overlapping: day)
            if !peaks.isEmpty {
                spans = peaks.map { .init(start: $0.start.timeIntervalSince(day.start) / day.duration, end: $0.end.timeIntervalSince(day.start) / day.duration) }
                break
            }
        }
        pricingSpans = spans
    }
}
