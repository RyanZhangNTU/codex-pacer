import Foundation

/// The Mac wallet's notification transitions, shared with platform hosts.
/// Initial spend establishes a baseline; only a later crossing emits a notice.
public struct DeepSeekNoticePolicy: Sendable {
    public static let spikeCategory = "deepseek.spike"
    public static let balanceCategory = "deepseek.balance"
    private var notified: DeepSeekWallet.State?
    private var spiking: Bool?
    private var budgetLevels: [String: Int]?
    public init() {}

    public mutating func balanceNotices(_ wallet: DeepSeekWallet, low: Bool = true) -> [IslandNotice] {
        let state = wallet.state
        guard [.low, .exhausted, .normal].contains(state) else { return [] }
        defer { notified = state == .normal ? nil : state }
        guard state != .normal, notified != state, notified != .exhausted || state == .exhausted, let balance = wallet.balance,
              state == .exhausted || low else { return [] }
        let detail = state == .exhausted ? L10n.text("deepseek.notice.exhausted_detail")
            : L10n.text("deepseek.notice.low_detail", DeepSeekWallet.compactAmount(balance.total))
        return [.init(id: "deepseek:balance:" + (state == .exhausted ? "exhausted" : "low"), kind: .lowQuota,
            title: "DeepSeek · " + L10n.text(state == .exhausted ? "deepseek.notice.exhausted" : "deepseek.notice.low"), detail: detail,
            category: Self.balanceCategory)]
    }

    public mutating func spendNotices(_ wallet: DeepSeekWallet, spike: Bool, budget: Bool, snoozedUntil: Date, now: Date) -> [IslandNotice] {
        var result: [IslandNotice] = []
        let wasSpiking = spiking
        spiking = wallet.spiking
        if spike, wallet.spiking, wasSpiking == false, now >= snoozedUntil {
            result.append(.init(id: "deepseek:spike", kind: .lowQuota, title: "DeepSeek · " + L10n.text("deepseek.notice.spike"),
                detail: L10n.text("deepseek.notice.spike_detail", DeepSeekWallet.compactSpend(wallet.recentSpend),
                    DeepSeekWallet.compactSpend(wallet.spikeLimit)), category: Self.spikeCategory))
        }
        var levels: [String: Int] = [:]
        for period in [wallet.daily, wallet.weekly].compactMap({ $0 }) {
            let key = period.kind.rawValue + String(Int(period.interval.start.timeIntervalSince1970))
            let level = period.exceeded ? 2 : period.nearing ? 1 : 0
            levels[key] = level
            guard budget, let previous = budgetLevels, level > previous[key, default: 0] else { continue }
            let day = period.kind == .day
            result.append(.init(id: "deepseek:budget:" + key + ":" + String(level), kind: .lowQuota,
                title: "DeepSeek · " + L10n.text(level == 2 ? (day ? "deepseek.notice.day_over" : "deepseek.notice.week_over")
                    : (day ? "deepseek.notice.day_near" : "deepseek.notice.week_near")),
                detail: L10n.text(day ? "deepseek.notice.budget_detail_day" : "deepseek.notice.budget_detail_week",
                    DeepSeekDialPresentation.amount(period.spent), DeepSeekDialPresentation.amount(period.limit))))
        }
        budgetLevels = levels
        return result
    }
}
