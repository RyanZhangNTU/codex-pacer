import AppKit
import PacerCore
import SwiftUI

/// Settings → Collaboration. The pairs come first, one card each with its
/// switch; the selected pair's settings follow: the basic ones, then the
/// advanced ones folded away. Claude → Codex is the only pair so far. Every
/// choice applies at once; explanations wait behind ⓘ. Codex's own state
/// (version, sign-in) lives on its module page, so a pair card only names
/// what keeps it from working.
struct SettingsCollaborationPane: View {
    let model: IslandModel
    /// The switch and the choices need the Claude module; the page stays readable without it.
    let claudeEnabled: Bool
    let openPane: (SettingsPane) -> Void
    @State private var preferences = CodexDelegationPreferences(defaults: .standard)
    @State private var workbench = CodexDelegationWorkbench()
    @State private var check = CodexDelegationCheck()
    @State private var advancedExpanded = false
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    @State private var modelText = ""
    @FocusState private var modelFocused: Bool
    @State private var legacyIssue: String?

    private typealias Settings = ClaudeCodexDelegation.Settings

    var body: some View {
        pairs
            .task {
                modelText = preferences.model
                model.checkCodexDelegation()
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            .onReceive(model.$codexDelegationCheck) { value in if check != value { check = value } }
        basic
        advanced
    }

    // MARK: Pairs

    private var pairs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("collab.pairs")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                pairCard
            }
        }
    }

    private var pairCard: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .topLeading) {
                ProviderAppIcon(provider: .claude, size: 24)
                ProviderAppIcon(provider: .codex, size: 22).offset(x: 14, y: 7)
            }
            .frame(width: 38, height: 30, alignment: .topLeading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("collab.pair.claude_codex")).font(.system(size: 13.5, weight: .semibold))
                if let problem {
                    Text(problem.text).font(.system(size: 11.5)).foregroundStyle(MainPalette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = problem.action { action }
                }
            }
            Spacer(minLength: 8)
            Toggle(L10n.text("collab.pair.claude_codex"), isOn: binding(\.enabled))
                .labelsHidden().toggleStyle(.switch).disabled(!claudeEnabled)
        }
        .padding(14)
        .background(MainPalette.card, in: shape)
        .overlay(shape.strokeBorder(PacerAccent.current.control, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    /// What keeps the pair from working, with the one step that fixes it.
    private var problem: (text: String, action: AnyView?)? {
        if !claudeEnabled { return (L10n.text("collab.reason.claude_off"), nil) }
        if let legacy = workbench.legacySkill {
            return (legacyIssue ?? L10n.text("collab.reason.legacy"),
                    AnyView(Button(L10n.text("collab.legacy_remove")) { removeLegacySkill(legacy) }.buttonStyle(.main)))
        }
        if !workbench.codexFound {
            return (L10n.text("collab.reason.codex_missing"), AnyView(Button(L10n.text("collab.go_codex")) { openPane(.codex) }.buttonStyle(.main)))
        }
        if check.login == "missing" {
            return (L10n.text("collab.reason.signed_out"), AnyView(Button(L10n.text("collab.open_codex")) { model.openCodexApplication() }.buttonStyle(.main)))
        }
        if preferences.enabled && !workbench.skillInstalled {
            return (L10n.text("collab.reason.setup"), AnyView(Button(L10n.text("collab.retry")) {
                model.reinstallCodexDelegationSkill(); refresh()
            }.buttonStyle(.main)))
        }
        return nil
    }

    // MARK: Basic

    private var basic: some View {
        let restore = Button(L10n.text("common.restore_defaults")) { update { $0 = $0.restoringDefaults() } }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .disabled(!claudeEnabled || preferences.isDefault)
        return MainCard(title: L10n.text("collab.basic"), titleTrailing: AnyView(restore)) {
            CardRow(title: L10n.text("collab.trigger"), info: L10n.text("collab.info.trigger")) {
                menu("collab.trigger", binding(\.trigger), Settings.Trigger.allCases.map { ($0, L10n.text("collab.trigger." + $0.rawValue)) })
            }
            CardRow(title: L10n.text("collab.model"), detail: codexDefault(check.defaultModel.map(modelName))) {
                if !preferences.followModel { modelPicker }
                followSegment("collab.model", follow: followModel)
            }
            CardRow(title: L10n.text("collab.effort"), detail: codexDefault(check.defaultEffort.map(effortName))) {
                if !preferences.followEffort {
                    menu("collab.effort", binding(\.effort), effortChoices.map { ($0, effortName($0)) })
                }
                followSegment("collab.effort", follow: followEffort)
            }
            CardRow(title: L10n.text("collab.fast"), detail: codexDefault(check.defaultFast.map { L10n.text($0 ? "collab.on" : "collab.off") })) {
                if !preferences.followFast {
                    menu("collab.fast", binding(\.fast), [(true, L10n.text("collab.on")), (false, L10n.text("collab.off"))])
                }
                followSegment("collab.fast", follow: followFast)
            }
            CardRow(title: L10n.text("collab.records"), detail: L10n.text("collab.records.hint"), info: L10n.text("collab.info.records")) {
                if preferences.records == .timed {
                    menu("collab.records", binding(\.recordsHours), Settings.recordsHourChoices.map { ($0, Self.duration($0)) })
                }
                MainSegmented(options: Settings.Records.allCases.map { ($0, L10n.text("collab.records." + $0.rawValue)) },
                              selection: binding(\.records), label: L10n.text("collab.records"))
                    .disabled(!claudeEnabled)
            }
        }
    }

    private func codexDefault(_ value: String?) -> String? { value.map { L10n.text("collab.codex_default", $0) } }

    private func followSegment(_ key: String, follow: Binding<Bool>) -> some View {
        MainSegmented(options: [(true, L10n.text("collab.follow")), (false, L10n.text("collab.pick"))], selection: follow, label: L10n.text(key))
            .disabled(!claudeEnabled)
    }

    /// Picking a model starts from Codex's own, the first time.
    private var followModel: Binding<Bool> {
        Binding(get: { preferences.followModel }, set: { follow in
            update { value in
                value.followModel = follow
                if !follow, value.model.isEmpty { value.model = check.defaultModel ?? check.models?.first?.slug ?? "" }
            }
            modelText = preferences.model
        })
    }
    private var followEffort: Binding<Bool> {
        Binding(get: { preferences.followEffort }, set: { follow in
            update { value in
                value.setFollowEffort(follow, fallback: check.defaultEffort)
            }
        })
    }
    private var followFast: Binding<Bool> {
        Binding(get: { preferences.followFast }, set: { follow in
            update { value in
                value.setFollowFast(follow, fallback: check.defaultFast)
            }
        })
    }

    /// Codex's catalog, with a saved model it no longer lists kept choosable.
    /// Until the catalog is known, a field.
    @ViewBuilder private var modelPicker: some View {
        if let models = check.models {
            let options = models.map { ($0.slug, $0.name) }
                + (models.contains { $0.slug == preferences.model } || preferences.model.isEmpty ? [] : [(preferences.model, preferences.model)])
            menu("collab.model", binding(\.model), options)
        } else {
            TextField(L10n.text("collab.model"), text: $modelText, prompt: Text(verbatim: "gpt-…"))
                .textFieldStyle(.roundedBorder).labelsHidden().font(.system(size: 12.5)).frame(width: 150)
                .focused($modelFocused).onSubmit(commitModel)
                .onChange(of: modelFocused) { _, focused in if !focused { commitModel() } }
                .onDisappear(perform: commitModel)
                .disabled(!claudeEnabled)
        }
    }

    /// The efforts the chosen (or Codex's) model supports, else every level.
    private var effortChoices: [String] {
        let slug = preferences.followModel ? check.defaultModel : preferences.model
        let supported = check.models?.first { $0.slug == slug }?.efforts ?? []
        var choices = supported.isEmpty ? CodexDelegationPreferences.efforts : supported
        if !choices.contains(preferences.effort) { choices.append(preferences.effort) }
        return choices
    }

    private func modelName(_ slug: String) -> String { check.models?.first { $0.slug == slug }?.name ?? ModelDisplay.name(slug, provider: .codex) }
    private func effortName(_ effort: String) -> String { effort }

    static func duration(_ hours: Int) -> String {
        hours < 24 ? L10n.text("collab.hours", hours) : hours == 24 ? L10n.text("collab.day") : L10n.text("collab.days", hours / 24)
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        MainCard {
            CardDisclosure(title: L10n.text("collab.advanced"),
                           summary: L10n.text(preferences.advancedIsDefault ? "collab.advanced.summary" : "collab.advanced.summary_changed"),
                           isExpanded: $advancedExpanded)
        }
        if advancedExpanded {
            MainCard(title: L10n.text("collab.section.access")) {
                CardRow(title: L10n.text("collab.sandbox"), info: L10n.text("collab.info.sandbox")) {
                    menu("collab.sandbox", binding(\.sandbox), Settings.Sandbox.allCases.map { ($0, L10n.text("collab.sandbox." + $0.rawValue)) })
                }
                CardRow(title: L10n.text("collab.location"), info: L10n.text("collab.info.location")) {
                    MainSegmented(options: [(false, L10n.text("collab.location.project")), (true, L10n.text("collab.location.worktree"))],
                                  selection: binding(\.worktree), label: L10n.text("collab.location"))
                        .disabled(!claudeEnabled || preferences.sandbox == .readOnly)
                }
            }
            MainCard(title: L10n.text("collab.section.context")) {
                CardRow(title: L10n.text("collab.instructions"), info: L10n.text("collab.info.instructions")) {
                    Text(preferences.instructions.isEmpty ? L10n.text("collab.instructions.none") : preferences.instructions)
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .trailing)
                    Button(L10n.text("collab.edit")) { instructionsDraft = preferences.instructions; editingInstructions = true }
                        .buttonStyle(.main).disabled(!claudeEnabled)
                        .popover(isPresented: $editingInstructions, arrowEdge: .bottom) { instructionsEditor }
                }
                CardToggle(title: L10n.text("collab.memory"), info: L10n.text("collab.info.memory"), isOn: binding(\.memory))
                    .disabled(!claudeEnabled)
            }
            MainCard(title: L10n.text("collab.section.limits")) {
                CardRow(title: L10n.text("collab.concurrency"), detail: L10n.text("collab.concurrency.hint")) {
                    menu("collab.concurrency", binding(\.maxConcurrent), Settings.concurrencyChoices.map { ($0, String($0)) })
                }
                CardRow(title: L10n.text("collab.quota_floor"), detail: L10n.text("collab.quota_floor.hint")) {
                    menu("collab.quota_floor", binding(\.quotaFloor),
                         [(0, L10n.text("collab.quota_floor.none"))] + Settings.quotaFloorChoices.map { ($0, String($0) + "%") })
                }
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("collab.instructions")).font(.system(size: 13, weight: .semibold))
            TextEditor(text: $instructionsDraft)
                .font(.system(size: 12.5)).frame(width: 340, height: 150)
                .overlay(alignment: .topLeading) {
                    if instructionsDraft.isEmpty {
                        Text(L10n.text("collab.instructions.placeholder")).font(.system(size: 12.5)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .onChange(of: instructionsDraft) { _, value in
                    if value.count > Settings.instructionsLimit { instructionsDraft = String(value.prefix(Settings.instructionsLimit)) }
                }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { editingInstructions = false }.buttonStyle(.main)
                Button(L10n.text("collab.done")) {
                    let text = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    update { $0.instructions = text }
                    editingInstructions = false
                }
                .buttonStyle(.mainProminent)
            }
        }
        .padding(14)
    }

    // MARK: State

    private func menu<Value: Hashable>(_ key: String, _ selection: Binding<Value>, _ options: [(Value, String)]) -> some View {
        OutlineMenu(title: L10n.text(key), selection: selection, options: options).disabled(!claudeEnabled)
    }

    private func refresh() {
        // Another window (the welcome page) may have changed a choice.
        let fresh = CodexDelegationPreferences(defaults: .standard)
        if fresh != preferences {
            preferences = fresh
            if !modelFocused { modelText = fresh.model }
        }
        let value = model.codexDelegationWorkbench()
        if value != workbench { workbench = value }
    }

    /// Changes one choice on what is saved now, so choices made elsewhere
    /// stay; the runner's config and the skill follow at once.
    private func update(_ change: (inout CodexDelegationPreferences) -> Void) {
        var value = CodexDelegationPreferences(defaults: .standard)
        change(&value)
        value.save(to: .standard)
        preferences = value
        model.applyCodexDelegationPreferences()
        refresh()
    }

    private func binding<Value>(_ key: WritableKeyPath<CodexDelegationPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    private func commitModel() {
        let value = modelText.trimmingCharacters(in: .whitespaces)
        guard CodexDelegationPreferences.validModel(value) else { modelText = preferences.model; return }
        modelText = value
        guard value != preferences.model else { return }
        update { $0.model = value }
    }

    /// The earlier user-level skill goes to the Trash, where the user can put it
    /// back; only that exact folder in this Claude home is touched.
    private func removeLegacySkill(_ folder: URL) {
        guard folder == ClaudeCodexDelegation.legacySkillURL(home: model.claudeHome),
              ClaudeCodexDelegation.hasLegacySkill(home: model.claudeHome) else { return }
        NSWorkspace.shared.recycle([folder]) { _, error in
            Task { @MainActor in
                legacyIssue = error == nil ? nil : L10n.text("collaboration.legacy_failed")
                refresh()
            }
        }
    }
}
