import Foundation

/// The one wallet warning chosen by the original priority rules.
public struct DeepSeekAlertPresentation: Codable, Equatable, Sendable {
    public let kind: String
    public let budgetKind: String?
    public let solid: Bool
    public let label: String?
    public let symbol: String?
    public let help: String

    public init?(wallet: DeepSeekWallet, lowBalance: Bool, spike: Bool, budget: Bool) {
        guard let alert = wallet.alert(lowBalance: lowBalance, spike: spike, budget: budget) else { return nil }
        solid = alert.solid
        switch alert {
        case .exhausted:
            kind = "exhausted"; budgetKind = nil; label = "¥"; symbol = nil
            help = "DeepSeek · " + L10n.text("deepseek.notice.exhausted")
        case .lowBalance:
            kind = "lowBalance"; budgetKind = nil; label = "¥"; symbol = nil
            help = "DeepSeek · " + L10n.text("deepseek.notice.low")
        case .spike:
            kind = "spike"; budgetKind = nil; label = nil; symbol = "flame.fill"
            help = "DeepSeek · " + L10n.text("deepseek.notice.spike")
        case .overBudget(let period):
            kind = "overBudget"; budgetKind = period.rawValue; label = L10n.text("deepseek.alert." + period.rawValue); symbol = nil
            help = "DeepSeek · " + L10n.text(period == .day ? "deepseek.notice.day_over" : "deepseek.notice.week_over")
        case .nearingBudget(let period):
            kind = "nearingBudget"; budgetKind = period.rawValue; label = L10n.text("deepseek.alert." + period.rawValue); symbol = nil
            let used = Int(((wallet.budget(period)?.usedFraction ?? 0.8) * 100).rounded())
            help = "DeepSeek · " + L10n.text(period == .day ? "deepseek.alert.day_used" : "deepseek.alert.week_used", used)
        }
    }
}
