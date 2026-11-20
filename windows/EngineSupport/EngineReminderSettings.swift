import Foundation
import PacerCore

struct EngineReminderSettings: Codable, Equatable, Sendable {
    var warnings = CompactIslandLayout.Warning.allCases.map(\.rawValue)
    var lowLine: Double?
    var spikeLine: Double?
    /// Days ahead that a Codex banked reset's deadline counts as soon; nil is the default.
    var resetDays: Int?
    var isValid: Bool {
        Set(warnings).count == warnings.count && Set(warnings).isSubset(of: Set(CompactIslandLayout.Warning.allCases.map(\.rawValue)))
            && [lowLine, spikeLine].compactMap { $0 }.allSatisfy { $0.isFinite && $0 > 0 }
            && resetDays.map(ResetExpiryReminder.leadDayRange.contains) ?? true
    }
    func contains(_ kind: CompactIslandLayout.Warning) -> Bool { warnings.contains(kind.rawValue) }
}

struct EngineReminderReading: Codable, Equatable {
    let lowPlaceholder: String
    let spikePlaceholder: String
    init(low: Double, spike: Double) {
        func placeholder(_ amount: Double) -> String {
            let shown = amount.rounded() == amount || amount >= 100 ? String(Int(amount.rounded())) : String(format: "%.1f", amount)
            return L10n.text("reminders.amount_auto", shown)
        }
        lowPlaceholder = placeholder(low); spikePlaceholder = placeholder(spike)
    }
}
