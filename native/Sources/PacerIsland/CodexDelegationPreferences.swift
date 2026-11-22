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
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey); defaults.set(rows, forKey: Self.rowsKey)
        defaults.set(model, forKey: Self.modelKey); defaults.set(effort, forKey: Self.effortKey)
        defaults.set(fast, forKey: Self.fastKey); defaults.set(write, forKey: Self.writeKey)
        defaults.set(timeoutMinutes, forKey: Self.timeoutKey); defaults.set(maxConcurrent, forKey: Self.concurrencyKey)
    }

    /// A model slug: letters, digits and the punctuation Codex uses in them.
    static func validModel(_ value: String) -> Bool {
        value.isEmpty || value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}\z"#, options: .regularExpression) != nil
    }

    /// What the runner reads from `config.json`, with the Codex program Pacer found.
    func settings(codex: String?) -> ClaudeCodexDelegation.Settings {
        .init(codex: codex, model: model.isEmpty ? nil : String(model.prefix(80)), effort: effort.isEmpty ? nil : effort,
              fast: fast.isEmpty ? nil : fast == "on", sandbox: write ? .workspaceWrite : .readOnly,
              timeoutMinutes: timeoutMinutes, maxConcurrent: maxConcurrent)
    }
}

private extension Optional where Wrapped == String {
    func filter(_ valid: (String) -> Bool) -> String? { flatMap { valid($0) ? $0 : nil } }
}
private extension Optional where Wrapped == Int {
    func filter(_ valid: (Int) -> Bool) -> Int? { flatMap { valid($0) ? $0 : nil } }
}
