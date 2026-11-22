import Foundation
import PacerCore

/// Settings → Collaboration: Codex for Claude, off until the user turns it on.
/// The same choices as Windows' `CodexDelegation*` preferences. Empty model and
/// effort, and an empty fast choice, follow Codex's own configuration; the
/// runner applies these when Claude leaves them out.
struct CodexDelegationPreferences: Equatable {
    static let enabledKey = "codexDelegation"
    static let rowsKey = "codexDelegationRows"
    static let modelKey = "codexDelegationModel"
    static let effortKey = "codexDelegationEffort"
    static let fastKey = "codexDelegationFast"
    static let writeKey = "codexDelegationWrite"
    static let timeoutKey = "codexDelegationTimeout"
    static let concurrencyKey = "codexDelegationConcurrency"
    static let initiativeKey = "codexDelegationInitiative"
    static let failureAlertsKey = "codexDelegationFailureAlerts"
    static let longRunKey = "codexDelegationLongRun"
    static let coachShownKey = "codexDelegationCoachShown"
    static let statsDaysKey = "codexDelegationStatsDays"
    static let longRunChoices = [0, 10, 20, 30, 60]
    static let efforts = ["", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let fastChoices = ["", "on", "off"]

    var enabled = false
    /// Runs show as rows under their Claude task; false shows only their count.
    var rows = true
    var model = ""
    var effort = ""
    var fast = ""
    var write = false
    var timeoutMinutes = 60
    var maxConcurrent = 3
    /// How freely Claude starts runs; written into the skill.
    var initiative = ClaudeCodexDelegation.Settings.Initiative.ask
    /// Notices: a failed or timed-out run (on), a run longer than these minutes (0 is off).
    var failureAlerts = true
    var longRunMinutes = 0
    /// The island's one-time hint about run lines was dismissed.
    var coachShown = false
    /// Collaboration's statistics show this many days: 7 or 30.
    var statsDays = 30

    init() {}
    init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        rows = defaults.object(forKey: Self.rowsKey) as? Bool ?? true
        model = defaults.string(forKey: Self.modelKey).filter(Self.validModel) ?? ""
        effort = defaults.string(forKey: Self.effortKey).filter { Self.efforts.contains($0) } ?? ""
        fast = defaults.string(forKey: Self.fastKey).filter { Self.fastChoices.contains($0) } ?? ""
        write = defaults.bool(forKey: Self.writeKey)
        timeoutMinutes = (defaults.object(forKey: Self.timeoutKey) as? Int).filter { ClaudeCodexDelegation.Settings.timeoutChoices.contains($0) } ?? 60
        maxConcurrent = (defaults.object(forKey: Self.concurrencyKey) as? Int).filter { ClaudeCodexDelegation.Settings.concurrencyChoices.contains($0) } ?? 3
        initiative = defaults.string(forKey: Self.initiativeKey).flatMap(ClaudeCodexDelegation.Settings.Initiative.init) ?? .ask
        failureAlerts = defaults.object(forKey: Self.failureAlertsKey) as? Bool ?? true
        longRunMinutes = (defaults.object(forKey: Self.longRunKey) as? Int).filter { Self.longRunChoices.contains($0) } ?? 0
        coachShown = defaults.bool(forKey: Self.coachShownKey)
        statsDays = (defaults.object(forKey: Self.statsDaysKey) as? Int).filter { [7, 30].contains($0) } ?? 30
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey); defaults.set(rows, forKey: Self.rowsKey)
        defaults.set(model, forKey: Self.modelKey); defaults.set(effort, forKey: Self.effortKey)
        defaults.set(fast, forKey: Self.fastKey); defaults.set(write, forKey: Self.writeKey)
        defaults.set(timeoutMinutes, forKey: Self.timeoutKey); defaults.set(maxConcurrent, forKey: Self.concurrencyKey)
        defaults.set(initiative.rawValue, forKey: Self.initiativeKey); defaults.set(failureAlerts, forKey: Self.failureAlertsKey)
        defaults.set(longRunMinutes, forKey: Self.longRunKey); defaults.set(coachShown, forKey: Self.coachShownKey)
        defaults.set(statsDays, forKey: Self.statsDaysKey)
    }

    /// A model slug: letters, digits and the punctuation Codex uses in them.
    static func validModel(_ value: String) -> Bool {
        value.isEmpty || value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}\z"#, options: .regularExpression) != nil
    }

    /// What the runner reads from `config.json`, with the Codex program Pacer found.
    func settings(codex: String?) -> ClaudeCodexDelegation.Settings {
        .init(codex: codex, model: model.isEmpty ? nil : String(model.prefix(80)), effort: effort.isEmpty ? nil : effort,
              fast: fast.isEmpty ? nil : fast == "on", sandbox: write ? .workspaceWrite : .readOnly,
              timeoutMinutes: timeoutMinutes, maxConcurrent: maxConcurrent, initiative: initiative)
    }
}

private extension Optional where Wrapped == String {
    func filter(_ valid: (String) -> Bool) -> String? { flatMap { valid($0) ? $0 : nil } }
}
private extension Optional where Wrapped == Int {
    func filter(_ valid: (Int) -> Bool) -> Int? { flatMap { valid($0) ? $0 : nil } }
}
