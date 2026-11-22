import AppKit
import PacerCore
import SwiftUI

/// Settings → Collaboration, as on Windows: Codex for Claude's switch, its
/// status, how runs show, the defaults the runner applies when Claude leaves
/// them out, and the last week's runs. Explanations wait behind ⓘ. Each choice
/// applies at once.
struct SettingsCollaborationPane: View {
    @ObservedObject var model: IslandModel
    /// The switch needs the Claude module; the page stays readable without it.
    let claudeEnabled: Bool
    @State private var preferences = CodexDelegationPreferences(defaults: .standard)
    @State private var modelText = CodexDelegationPreferences(defaults: .standard).model
    @FocusState private var modelFocused: Bool
    @State private var status: CodexDelegationStatus?
    @State private var legacyIssue: String?

    var body: some View {
        MainCard {
            CardToggle(title: L10n.text("collaboration.codex_for_claude"), info: L10n.text("collaboration.info.codex_for_claude"),
                       isOn: binding(\.enabled))
                .disabled(!claudeEnabled)
        }
        // Cheap file checks; the skill appears a moment after the switch turns on.
        .task(id: preferences.enabled) {
            while !Task.isCancelled {
                let home = model.claudeHome, custom = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
                let value = await Task.detached(priority: .utility) { CodexDelegationStatus.read(home: home, customCodex: custom, at: Date()) }.value
                if !Task.isCancelled, status != value { status = value }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if preferences.enabled {
            MainCard(title: L10n.text("main.section.status")) {
                let found = status?.codexFound != false
                ModuleStatusRow(title: L10n.text("collaboration.codex_program"),
                                state: L10n.text(found ? "collaboration.codex_found" : "collaboration.codex_missing"),
                                tone: status == nil ? .neutral : found ? .positive : .attention)
                ModuleStatusRow(title: L10n.text("collaboration.skill"),
                                state: L10n.text(status?.skillInstalled == true ? "collaboration.skill_installed" : "collaboration.skill_waiting"),
                                tone: status?.skillInstalled == true ? .positive : .neutral)
                if let legacy = status?.legacySkill {
                    CardRow(title: L10n.text("collaboration.legacy"), detail: legacyIssue ?? legacy.path, info: L10n.text("collaboration.info.legacy")) {
                        Button(L10n.text("collaboration.legacy_remove_mac")) { removeLegacySkill(legacy) }.buttonStyle(.main)
                    }
                }
            }
            MainCard(title: L10n.text("main.section.display")) {
                CardPicker(title: L10n.text("collaboration.display"), selection: binding(\.rows),
                           options: [(true, L10n.text("collaboration.display.rows")), (false, L10n.text("collaboration.display.count"))])
            }
            MainCard(title: L10n.text("collaboration.section.defaults"), info: L10n.text("collaboration.info.defaults")) {
                CardRow(title: L10n.text("collaboration.model")) {
                    TextField(L10n.text("collaboration.model"), text: $modelText, prompt: Text(L10n.text("collaboration.model_hint")))
                        .textFieldStyle(.roundedBorder).labelsHidden().font(.system(size: 12.5)).frame(width: 200)
                        .focused($modelFocused).onSubmit(commitModel)
                        .onChange(of: modelFocused) { _, focused in if !focused { commitModel() } }
                }
                CardPicker(title: L10n.text("collaboration.effort"), selection: binding(\.effort),
                           options: CodexDelegationPreferences.efforts.map { ($0, $0.isEmpty ? follow : L10n.text("collaboration.effort." + $0)) })
                CardPicker(title: L10n.text("collaboration.fast"), selection: binding(\.fast),
                           options: [("", follow), ("on", L10n.text("collaboration.fast.on")), ("off", L10n.text("collaboration.fast.off"))])
                CardPicker(title: L10n.text("collaboration.access"), info: L10n.text("collaboration.info.access"), selection: binding(\.write),
                           options: [(false, L10n.text("collaboration.access.read_only")), (true, L10n.text("collaboration.access.write"))])
                CardPicker(title: L10n.text("collaboration.timeout"), selection: binding(\.timeoutMinutes),
                           options: ClaudeCodexDelegation.Settings.timeoutChoices.map { ($0, "\($0) " + L10n.text("collaboration.unit.minutes")) })
                CardPicker(title: L10n.text("collaboration.concurrency"), selection: binding(\.maxConcurrent),
                           options: ClaudeCodexDelegation.Settings.concurrencyChoices.map { ($0, "\($0)") })
            }
            MainCard(title: L10n.text("collaboration.section.week")) {
                CardRow(title: status?.weekText ?? "—")
            }
        }
    }

    private var follow: String { L10n.text("collaboration.follow") }

    private func binding<Value>(_ key: WritableKeyPath<CodexDelegationPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: key] }, set: { value in
            preferences[keyPath: key] = value
            save()
        })
    }

    private func commitModel() {
        let value = modelText.trimmingCharacters(in: .whitespaces)
        guard CodexDelegationPreferences.validModel(value) else { modelText = preferences.model; return }
        modelText = value
        guard value != preferences.model else { return }
        preferences.model = value
        save()
    }

    private func save() {
        preferences.save(to: .standard)
        model.applyCodexDelegationPreferences()
    }

    /// The earlier user-level skill goes to the Trash, where the user can put it
    /// back; only that exact folder in this Claude home is touched.
    private func removeLegacySkill(_ folder: URL) {
        guard folder == ClaudeCodexDelegation.legacySkillURL(home: model.claudeHome),
              ClaudeCodexDelegation.hasLegacySkill(home: model.claudeHome) else { return }
        NSWorkspace.shared.recycle([folder]) { _, error in
            Task { @MainActor in
                legacyIssue = error == nil ? nil : L10n.text("collaboration.legacy_failed")
                if error == nil, let current = status {
                    status = CodexDelegationStatus(skillInstalled: current.skillInstalled, legacySkill: nil,
                                                   codexFound: current.codexFound, weekText: current.weekText)
                }
            }
        }
    }
}

/// What Settings → Collaboration shows about Codex for Claude: no task content.
struct CodexDelegationStatus: Equatable, Sendable {
    let skillInstalled: Bool
    let legacySkill: URL?
    let codexFound: Bool
    let weekText: String

    static func read(home: URL, customCodex: String, at date: Date) -> Self {
        let summary = ClaudeCodexDelegation.summary(home: home, since: date.addingTimeInterval(-7 * 86400))
        let minutes = Int((summary.seconds / 60).rounded())
        let week = summary.runs == 0 ? L10n.text("collaboration.week_none")
            : L10n.text("collaboration.week", summary.runs, minutes, summary.failures) + " · " + L10n.text("collaboration.week_tokens", max(1, summary.tokens / 1000))
        return Self(skillInstalled: FileManager.default.fileExists(atPath: ClaudeCodexDelegation.skillURL(home: home).path),
                    legacySkill: ClaudeCodexDelegation.hasLegacySkill(home: home) ? ClaudeCodexDelegation.legacySkillURL(home: home) : nil,
                    codexFound: CodexClient.findExecutable(customPath: customCodex) != nil, weekText: week)
    }
}
