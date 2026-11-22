import AppKit
import PacerCore
import SwiftUI

/// Settings → Collaboration, Codex for Claude's workbench, as on Windows: a
/// header with the switch and a status strip; until the first run, how it
/// works and three steps to start; then what runs now, the statistics,
/// recent runs, the defaults the runner applies when Claude leaves them out,
/// display and alerts, and checks. Explanations wait behind ⓘ; each choice
/// applies at once.
///
/// The page itself does not observe the model, whose runs change every
/// second: only the Running card and the strip's count do. The rest reads
/// the workbench every 3 seconds and right after an action, and the
/// self-check whenever it changes.
struct SettingsCollaborationPane: View {
    let model: IslandModel
    /// The switch and the choices need the Claude module; the page stays readable without it.
    let claudeEnabled: Bool
    @State private var preferences = CodexDelegationPreferences(defaults: .standard)
    @State private var modelText = ""
    @FocusState private var modelFocused: Bool
    @State private var workbench: CodexDelegationWorkbench?
    @State private var check = CodexDelegationCheck()
    @State private var howExpanded = false
    @State private var legacyIssue: String?

    var body: some View {
        header
            .task {
                modelText = preferences.model
                // Codex's version, sign-in and models, once each time the page opens.
                model.checkCodexDelegation()
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            .onReceive(model.$codexDelegationCheck) { value in if check != value { check = value } }
        if let workbench { sections(workbench) }
    }

    @ViewBuilder private func sections(_ workbench: CodexDelegationWorkbench) -> some View {
        let enabled = preferences.enabled
        if !enabled || !workbench.firstRunSeen {
            MainCard { SettingsCollaborationHowItWorks() }
            startSteps(workbench)
        }
        if enabled {
            if workbench.firstRunSeen && workbench.runsTotal < 3 { tryIt }
            SettingsCollaborationRunningCard(model: model, limit: workbench.limit)
            if workbench.firstRunSeen, let stats = preferences.statsDays == 7 ? workbench.stats7 : workbench.stats30 {
                SettingsCollaborationStatisticsCard(stats: stats, quota: workbench.quotaText, days: statsDays)
                SettingsCollaborationRecentCard(recent: stats.recent) {
                    model.clearCodexDelegationHistory()
                    refresh()
                }
                MainCard {
                    CardDisclosure(title: L10n.text("collaboration.how.title"), isExpanded: $howExpanded)
                    if howExpanded { SettingsCollaborationHowItWorks() }
                }
            }
            editors
            checks(workbench)
        }
    }

    // MARK: Header and getting started

    private var header: some View {
        MainCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 6) {
                        ProviderAppIcon(provider: .claude, size: 26)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        ProviderAppIcon(provider: .codex, size: 26)
                    }
                    .accessibilityHidden(true)
                    CardRow(title: L10n.text("collaboration.codex_for_claude"), info: L10n.text("collaboration.info.codex_for_claude")) {
                        Toggle(L10n.text("collaboration.codex_for_claude"), isOn: binding(\.enabled))
                            .labelsHidden().toggleStyle(.switch).disabled(!claudeEnabled)
                    }
                    .padding(.top, 2)
                }
                FlowRow(spacing: 6, lineSpacing: 6) { strip }
            }
            .padding(.vertical, 4)
        }
    }

    /// Ready or what needs attention, Codex's version and sign-in, the skill, and the runs going now.
    @ViewBuilder private var strip: some View {
        if !preferences.enabled {
            SettingsCollaborationPill(text: L10n.text("collaboration.status.off"))
        } else if let workbench {
            let ready = workbench.codexFound && workbench.skillInstalled && check.login != "missing"
            SettingsCollaborationPill(text: L10n.text(ready ? "collaboration.status.ready" : "collaboration.status.attention"),
                                      tint: ready ? MainPalette.positive : MainPalette.attention)
            if workbench.codexFound {
                SettingsCollaborationPill(text: codexLine, tint: check.login == "missing" ? MainPalette.attention : nil)
            }
            if workbench.skillInstalled { SettingsCollaborationPill(text: L10n.text("collaboration.status.skill_ready")) }
            SettingsCollaborationRunningPill(model: model)
        }
    }

    /// "Codex 0.171 · signed in", as far as the self-check knows.
    private var codexLine: String {
        "Codex" + (check.version.map { " " + $0 } ?? "") + (loginKey(unknown: nil).map { " · " + L10n.text($0) } ?? "")
    }

    private func loginKey(unknown: String?) -> String? {
        switch check.login {
        case "ok": "collaboration.status.signed_in"
        case "missing": "collaboration.status.signed_out"
        default: unknown
        }
    }

    private var openCodex: some View {
        Button(L10n.text("collaboration.check.open_codex")) { model.openCodexApplication() }.buttonStyle(.mainProminent)
    }

    private func startSteps(_ workbench: CodexDelegationWorkbench) -> some View {
        let phrase = L10n.text("collaboration.try.review")
        return MainCard(title: L10n.text("collaboration.start.title")) {
            SettingsCollaborationStep(number: 1, done: workbench.codexFound && check.login != "missing", title: L10n.text("collaboration.start.find"),
                                      detail: workbench.codexFound ? codexLine : L10n.text("collaboration.start.find_missing")) {
                if check.login == "missing" { openCodex }
            }
            SettingsCollaborationStep(number: 2, done: preferences.enabled && workbench.skillInstalled,
                                      title: L10n.text("collaboration.start.turn_on"), detail: L10n.text("collaboration.start.turn_on_detail")) {
                if !preferences.enabled {
                    Button(L10n.text("collaboration.start.open")) { update { $0.enabled = true } }
                        .buttonStyle(.mainProminent).disabled(!claudeEnabled)
                }
            }
            SettingsCollaborationStep(number: 3, done: workbench.firstRunSeen, title: L10n.text("collaboration.start.try"), detail: "“" + phrase + "”") {
                SettingsCollaborationCopyButton(text: phrase)
            }
        }
    }

    private var tryIt: some View {
        MainCard(title: L10n.text("collaboration.try.title")) {
            ForEach(["review", "ask", "worktree"], id: \.self) { key in
                let phrase = L10n.text("collaboration.try." + key)
                HStack(spacing: 10) {
                    Text(phrase).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SettingsCollaborationCopyButton(text: phrase)
                }
            }
        }
    }

    // MARK: Defaults, display and alerts

    @ViewBuilder private var editors: some View {
        let follow = L10n.text("collaboration.follow"), minutes = " " + L10n.text("collaboration.unit.minutes")
        MainCard(title: L10n.text("collaboration.section.how_codex_runs"), info: L10n.text("collaboration.info.defaults")) {
            modelRow(follow)
            picker("collaboration.effort", binding(\.effort),
                   CodexDelegationPreferences.efforts.map { ($0, $0.isEmpty ? follow : L10n.text("collaboration.effort." + $0)) })
            picker("collaboration.fast", binding(\.fast),
                   CodexDelegationPreferences.fastChoices.map { ($0, $0.isEmpty ? follow : L10n.text("collaboration.fast." + $0)) })
        }
        MainCard(title: L10n.text("collaboration.section.limits")) {
            picker("collaboration.access", info: "collaboration.info.access", binding(\.write),
                   [(false, L10n.text("collaboration.access.read_only")), (true, L10n.text("collaboration.access.write"))])
            picker("collaboration.timeout", binding(\.timeoutMinutes), ClaudeCodexDelegation.Settings.timeoutChoices.map { ($0, String($0) + minutes) })
            picker("collaboration.concurrency", binding(\.maxConcurrent), ClaudeCodexDelegation.Settings.concurrencyChoices.map { ($0, String($0)) })
            picker("collaboration.initiative", info: "collaboration.info.initiative", binding(\.initiative),
                   ClaudeCodexDelegation.Settings.Initiative.allCases.map { ($0, L10n.text("collaboration.initiative." + $0.rawValue)) })
        }
        MainCard(title: L10n.text("collaboration.section.display_alerts")) {
            picker("collaboration.display", binding(\.rows),
                   [(true, L10n.text("collaboration.display.rows")), (false, L10n.text("collaboration.display.count"))])
            CardToggle(title: L10n.text("collaboration.failure_alerts"), isOn: binding(\.failureAlerts)).disabled(!claudeEnabled)
            picker("collaboration.long_run", binding(\.longRunMinutes),
                   CodexDelegationPreferences.longRunChoices.map { ($0, $0 == 0 ? L10n.text("collaboration.long_run.off") : String($0) + minutes) })
        }
    }

    /// A menu row whose ⓘ stays usable while the choice is disabled.
    private func picker<Value: Hashable>(_ key: String, info: String? = nil, _ selection: Binding<Value>, _ options: [(Value, String)]) -> some View {
        CardRow(title: L10n.text(key), info: info.map { L10n.text($0) }) {
            OutlineMenu(title: L10n.text(key), selection: selection, options: options).disabled(!claudeEnabled)
        }
    }

    /// Codex's model catalog with "follow Codex settings" first; a saved model
    /// it does not list stays choosable. Until the catalog is known, a field.
    @ViewBuilder private func modelRow(_ follow: String) -> some View {
        if let models = check.models {
            picker("collaboration.model", Binding(get: { preferences.model }, set: { value in modelText = value; update { $0.model = value } }),
                   modelOptions(models, follow: follow))
        } else {
            CardRow(title: L10n.text("collaboration.model")) {
                TextField(L10n.text("collaboration.model"), text: $modelText, prompt: Text(L10n.text("collaboration.model_hint")))
                    .textFieldStyle(.roundedBorder).labelsHidden().font(.system(size: 12.5)).frame(width: 200)
                    .focused($modelFocused).onSubmit(commitModel)
                    .onChange(of: modelFocused) { _, focused in if !focused { commitModel() } }
                    .onDisappear(perform: commitModel)
                    .disabled(!claudeEnabled)
            }
        }
    }

    private func modelOptions(_ models: [CodexModelChoice], follow: String) -> [(String, String)] {
        let current = check.defaultModel.map { slug in models.first { $0.slug == slug }?.name ?? slug }
        var options = [("", current.map { follow + " (" + $0 + ")" } ?? follow)] + models.map { ($0.slug, $0.name) }
        if !preferences.model.isEmpty, !models.contains(where: { $0.slug == preferences.model }) {
            options.append((preferences.model, preferences.model))
        }
        return options
    }

    // MARK: Checks

    private func checks(_ workbench: CodexDelegationWorkbench) -> some View {
        let run = Button(L10n.text(check.checking ? "collaboration.check.running" : "collaboration.check.run")) { model.checkCodexDelegation() }
            .buttonStyle(.main).disabled(check.checking)
        let program = !workbench.codexFound ? L10n.text("collaboration.codex_missing")
            : check.version.map { L10n.text("collaboration.check.version", $0) } ?? L10n.text("collaboration.codex_found")
        return MainCard(title: L10n.text("collaboration.section.checks"), titleTrailing: AnyView(run)) {
            ModuleStatusRow(title: L10n.text("collaboration.codex_program"), state: program, tone: workbench.codexFound ? .positive : .attention, help: program)
            let unknown = check.checking ? "collaboration.check.running" : "collaboration.check.login_unknown"
            ModuleStatusRow(title: L10n.text("collaboration.check.login"), state: L10n.text(loginKey(unknown: unknown) ?? unknown),
                            tone: check.login == "ok" ? .positive : check.login == "missing" ? .attention : .neutral) {
                if check.login == "missing" { openCodex }
            }
            ModuleStatusRow(title: L10n.text("collaboration.skill"),
                            state: L10n.text(workbench.skillInstalled ? "collaboration.check.skill_new_sessions" : "collaboration.skill_waiting"),
                            tone: workbench.skillInstalled ? .positive : .neutral) {
                Button(L10n.text("collaboration.check.reinstall")) {
                    model.reinstallCodexDelegationSkill()
                    refresh()
                }
                .buttonStyle(.main).disabled(!claudeEnabled)
            }
            if let legacy = workbench.legacySkill {
                CardRow(title: L10n.text("collaboration.legacy"), detail: legacyIssue ?? (legacy.path as NSString).abbreviatingWithTildeInPath,
                        info: L10n.text("collaboration.info.legacy_mac")) {
                    Button(L10n.text("collaboration.legacy_remove_mac")) { removeLegacySkill(legacy) }.buttonStyle(.main)
                }
            }
            if workbench.runsFolder != nil {
                ModuleStatusRow(title: L10n.text("collaboration.check.pending"), state: String(workbench.pending),
                                tone: workbench.pending > 0 ? .attention : .neutral) {
                    Button(L10n.text("collaboration.check.open_folder")) { model.openCodexDelegationRuns() }.buttonStyle(.main)
                }
            }
        }
    }

    // MARK: State

    private func refresh() {
        // Another window (the welcome page, the island's hint) may have changed a choice.
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
    private func update(apply: Bool = true, _ change: (inout CodexDelegationPreferences) -> Void) {
        var value = CodexDelegationPreferences(defaults: .standard)
        change(&value)
        value.save(to: .standard)
        preferences = value
        guard apply else { return }
        model.applyCodexDelegationPreferences()
        refresh()
    }

    private func binding<Value>(_ key: WritableKeyPath<CodexDelegationPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    /// The statistics' period only changes what this page shows.
    private var statsDays: Binding<Int> {
        Binding(get: { preferences.statsDays }, set: { value in update(apply: false) { $0.statsDays = value } })
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

// MARK: - Parts

/// Codex for Claude in five steps and its rules, as on Windows.
struct SettingsCollaborationHowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 6) {
                node("you") { FeatureSymbol(symbol: "text.bubble", size: 30, tint: Color(red: 91 / 255, green: 102 / 255, blue: 112 / 255)) }
                node("brief") { ProviderAppIcon(provider: .claude, size: 30) }
                node("run") { ProviderAppIcon(provider: .codex, size: 30) }
                node("check") { FeatureSymbol(symbol: "checkmark.circle", size: 30, tint: Color(red: 201 / 255, green: 103 / 255, blue: 58 / 255)) }
                node("clean") { FeatureSymbol(symbol: "sparkle", size: 30, tint: Color(red: 138 / 255, green: 109 / 255, blue: 29 / 255)) }
            }
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(["brief", "read_only", "quota", "writer"], id: \.self) { SettingsCollaborationPill(text: L10n.text("collaboration.rule." + $0)) }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("collaboration.how.title"))
    }

    private func node<Icon: View>(_ key: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 5) {
            icon()
            Text(L10n.text("collaboration.how." + key)).font(.system(size: 12, weight: .semibold))
            Text(L10n.text("collaboration.how." + key + "_detail")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A rounded label, with a colored dot when it reports a state.
struct SettingsCollaborationPill: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let tint { Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(text).font(.system(size: 12)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(MainPalette.fill, in: Capsule())
    }
}

/// One of the three steps to start: a number, or a check once done.
private struct SettingsCollaborationStep<Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var action: Action
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    if done {
                        Circle().fill(SettingsCollaborationInk.codex(scheme))
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                        Text(verbatim: String(number)).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: done ? "✓" : ""))
            Spacer(minLength: 8)
            action
        }
    }
}

/// Copies an example to say to Claude.
private struct SettingsCollaborationCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(L10n.text(copied ? "collaboration.copied" : "collaboration.copy")) {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(.main)
        .accessibilityLabel(L10n.text("collaboration.copy") + " " + text)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
