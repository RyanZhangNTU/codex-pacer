import Foundation
import PacerCore

/// Settings → Collaboration for one pair, Claude → Codex, off until the user
/// turns it on. Keys carry the pair, so later pairs get their own; keys from
/// earlier builds are ignored. Model, effort and fast mode follow Codex until
/// the user picks one, and a pick is remembered while they follow Codex again.
/// The runner applies these from `config.json`.
struct CodexDelegationPreferences: Equatable {
    static let pair = "collaboration.claude>codex."
    static let enabledKey = pair + "enabled"
    static let triggerKey = pair + "trigger"
    static let modelKey = pair + "model", followModelKey = pair + "followModel"
    static let effortKey = pair + "effort", followEffortKey = pair + "followEffort"
    static let fastKey = pair + "fast", followFastKey = pair + "followFast"
    static let recordsKey = pair + "records", recordsHoursKey = pair + "recordsHours"
    static let sandboxKey = pair + "sandbox"
    static let worktreeKey = pair + "worktree"
    static let instructionsKey = pair + "instructions"
    static let memoryKey = pair + "memory"
    static let concurrencyKey = pair + "concurrency"
    static let quotaFloorKey = pair + "quotaFloor"
    /// The first-run guide on Settings → Collaboration: closed for good, and
    /// what it has seen, a run and one that ended. Cleanup deletes runs, so
    /// each is kept once seen.
    static let introDoneKey = pair + "introDone", introRanKey = pair + "introRan", introFinishedKey = pair + "introFinished"
    static let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    typealias Settings = ClaudeCodexDelegation.Settings

    var enabled = false
    var trigger = Settings.Trigger.ask
    var followModel = true
    var model = ""
    var pickedEffort = false
    var followEffort = true
    var effort = "high"
    var pickedFast = false
    var followFast = true
    var fast = false
    var records = Settings.Records.turn
    var recordsHours = 24
    var sandbox = Settings.Sandbox.workspaceWriteNetwork
    var worktree = false
    var instructions = ""
    var memory = false
    var maxConcurrent = 3
    /// Percent of quota left below which runs don't start; 0 never holds them back.
    var quotaFloor = 0
    var introDone = false
    var introRan = false
    var introFinished = false

    mutating func setFollowEffort(_ follow: Bool, fallback: String?) {
        if !follow && !pickedEffort { effort = fallback ?? effort }
        pickedEffort = pickedEffort || !follow || !followEffort
        followEffort = follow
    }

    mutating func setFollowFast(_ follow: Bool, fallback: Bool?) {
        if !follow && !pickedFast { fast = fallback ?? fast }
        pickedFast = pickedFast || !follow || !followFast
        followFast = follow
    }

    init() {}
    init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        trigger = defaults.string(forKey: Self.triggerKey).flatMap(Settings.Trigger.init) ?? .ask
        followModel = defaults.object(forKey: Self.followModelKey) as? Bool ?? true
        model = defaults.string(forKey: Self.modelKey).filter(Self.validModel) ?? ""
        pickedEffort = defaults.bool(forKey: Self.pair + "pickedEffort")
        followEffort = defaults.object(forKey: Self.followEffortKey) as? Bool ?? true
        effort = defaults.string(forKey: Self.effortKey).filter { Self.efforts.contains($0) } ?? "high"
        pickedFast = defaults.bool(forKey: Self.pair + "pickedFast")
        followFast = defaults.object(forKey: Self.followFastKey) as? Bool ?? true
        fast = defaults.bool(forKey: Self.fastKey)
        records = defaults.string(forKey: Self.recordsKey).flatMap(Settings.Records.init) ?? .turn
        recordsHours = (defaults.object(forKey: Self.recordsHoursKey) as? Int).filter { Settings.recordsHourChoices.contains($0) } ?? 24
        sandbox = defaults.string(forKey: Self.sandboxKey).flatMap(Settings.Sandbox.init) ?? .workspaceWriteNetwork
        worktree = defaults.bool(forKey: Self.worktreeKey)
        instructions = String((defaults.string(forKey: Self.instructionsKey) ?? "").prefix(Settings.instructionsLimit))
        memory = defaults.bool(forKey: Self.memoryKey)
        maxConcurrent = (defaults.object(forKey: Self.concurrencyKey) as? Int).filter { Settings.concurrencyChoices.contains($0) } ?? 3
        quotaFloor = (defaults.object(forKey: Self.quotaFloorKey) as? Int).filter { Settings.quotaFloorChoices.contains($0) } ?? 0
        introDone = defaults.bool(forKey: Self.introDoneKey)
        introRan = defaults.bool(forKey: Self.introRanKey)
        introFinished = defaults.bool(forKey: Self.introFinishedKey)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey); defaults.set(trigger.rawValue, forKey: Self.triggerKey)
        defaults.set(followModel, forKey: Self.followModelKey); defaults.set(model, forKey: Self.modelKey)
        defaults.set(pickedEffort, forKey: Self.pair + "pickedEffort")
        defaults.set(followEffort, forKey: Self.followEffortKey); defaults.set(effort, forKey: Self.effortKey)
        defaults.set(pickedFast, forKey: Self.pair + "pickedFast")
        defaults.set(followFast, forKey: Self.followFastKey); defaults.set(fast, forKey: Self.fastKey)
        defaults.set(records.rawValue, forKey: Self.recordsKey); defaults.set(recordsHours, forKey: Self.recordsHoursKey)
        defaults.set(sandbox.rawValue, forKey: Self.sandboxKey); defaults.set(worktree, forKey: Self.worktreeKey)
        defaults.set(instructions, forKey: Self.instructionsKey); defaults.set(memory, forKey: Self.memoryKey)
        defaults.set(maxConcurrent, forKey: Self.concurrencyKey); defaults.set(quotaFloor, forKey: Self.quotaFloorKey)
        defaults.set(introDone, forKey: Self.introDoneKey); defaults.set(introRan, forKey: Self.introRanKey)
        defaults.set(introFinished, forKey: Self.introFinishedKey)
    }

    /// Everything but the switch back to its default; the switch and the guide's record stay.
    func restoringDefaults() -> Self {
        var value = Self(); value.enabled = enabled
        value.introDone = introDone; value.introRan = introRan; value.introFinished = introFinished
        return value
    }
    /// Whether every choice besides the switch is at its default.
    var isDefault: Bool { restoringDefaults() == self }
    /// Whether every advanced choice is at its default.
    var advancedIsDefault: Bool {
        let base = Self()
        return sandbox == base.sandbox && worktree == base.worktree && instructions.isEmpty && memory == base.memory
            && maxConcurrent == base.maxConcurrent && quotaFloor == base.quotaFloor
    }

    /// A model slug: letters, digits and the punctuation Codex uses in them.
    static func validModel(_ value: String) -> Bool {
        value.isEmpty || value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}\z"#, options: .regularExpression) != nil
    }

    /// What the runner reads from `config.json`, with the Codex program Pacer found.
    func settings(codex: String?) -> Settings {
        .init(codex: codex, model: followModel || model.isEmpty ? nil : String(model.prefix(80)), effort: followEffort ? nil : effort,
              fast: followFast ? nil : fast, trigger: trigger, records: records, recordsHours: recordsHours, sandbox: sandbox,
              worktree: worktree, instructions: instructions, memory: memory, maxConcurrent: maxConcurrent,
              quotaFloor: quotaFloor == 0 ? nil : quotaFloor)
    }
}

private extension Optional where Wrapped == String {
    func filter(_ valid: (String) -> Bool) -> String? { flatMap { valid($0) ? $0 : nil } }
}
private extension Optional where Wrapped == Int {
    func filter(_ valid: (Int) -> Bool) -> Int? { flatMap { valid($0) ? $0 : nil } }
}
