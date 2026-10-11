import AppKit
import SwiftUI
import PacerCore

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var updater: AppUpdater
    let onClose: () -> Void
    @State private var executable = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
    @State private var home = UserDefaults.standard.string(forKey: "codexHome") ?? ""
    @State private var modules = ProviderModules.load()
    @State private var claudeHome = UserDefaults.standard.string(forKey: "claudeHome") ?? ""
    @State private var claudeSSHHosts = UserDefaults.standard.string(forKey: "claudeSSHHosts") ?? ""
    @State private var showsResetExpiryDetails: Set<AgentProvider> = []
    @State private var displayMode = IslandDisplayMode.load()
    @State private var widthSettings = IslandWidthSettings.load()
    @State private var compactLayout = CompactIslandLayout.load()
    @State private var appearance = IslandAppearance.stored
    @State private var glass = IslandGlassSettings.stored
    @State private var fullscreen = UserDefaults.standard.bool(forKey: "showInFullscreen")
    @State private var showInMenuBar = UserDefaults.standard.bool(forKey: "showInMenuBar")
    @State private var displayID = UserDefaults.standard.integer(forKey: "displayID")
    @State private var metric = UserDefaults.standard.string(forKey: "compactMetric") ?? "remaining"
    @State private var singleTask = ActivityBadgeSingleTask()
    @State private var windowID = UserDefaults.standard.string(forKey: "quotaWindowID") ?? "auto"
    @State private var claudeWindowID = UserDefaults.standard.string(forKey: "claudeQuotaWindowID") ?? "auto"
    @State private var lowReminder = UserDefaults.standard.bool(forKey: "lowQuotaReminder")
    @State private var inputReminder = UserDefaults.standard.bool(forKey: "inputReminder")
    @State private var completionReminder = UserDefaults.standard.bool(forKey: "completionReminder")
    @State private var completedRetention = UserDefaults.standard.object(forKey: "completedRetentionMinutes") as? Int ?? 30
    @State private var systemNotifications = UserDefaults.standard.bool(forKey: "systemNotifications")
    @State private var hideProjects = UserDefaults.standard.bool(forKey: "hideProjects")
    @State private var monitorSSH = UserDefaults.standard.object(forKey: "monitorSSH") == nil || UserDefaults.standard.bool(forKey: "monitorSSH")
    @State private var monitorRemoteControl = UserDefaults.standard.object(forKey: "monitorRemoteControl") == nil || UserDefaults.standard.bool(forKey: "monitorRemoteControl")
    @State private var validation: String?
    @State private var saving = false
    @State private var language = LanguagePreference.load()
    @State private var automaticUpdateChecks = true
    @State private var cliReport: CodexExecutableResolver.Report?
    @State private var cliScanRevision = 0
    /// Custom locations stay folded away unless one is already set.
    @State private var expandedLocations: Set<AgentProvider> = {
        let defaults = UserDefaults.standard
        var result = Set<AgentProvider>()
        if !(defaults.string(forKey: "codexExecutable") ?? "").isEmpty || !(defaults.string(forKey: "codexHome") ?? "").isEmpty { result.insert(.codex) }
        if !(defaults.string(forKey: "claudeHome") ?? "").isEmpty { result.insert(.claude) }
        return result
    }()
    @State private var pane = UserDefaults.standard.string(forKey: SettingsPane.defaultsKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    private var languageChanges: Bool { language.resolved() != L10n.language }
    private var claudeSSHHostsChanged: Bool {
        claudeSSHHosts != (UserDefaults.standard.string(forKey: "claudeSSHHosts") ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(pane.title).font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 28).padding(.top, 20)
                    Form { paneContent }
                        .formStyle(.grouped)
                        .disabled(saving)
                        .id(pane)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 600)
        .environment(\.locale, L10n.locale)
        .onAppear {
            automaticUpdateChecks = updater.automaticallyChecks
            windowID = QuotaWindowSelection.validated(windowID, snapshot: model.providerQuota(.codex))
            claudeWindowID = QuotaWindowSelection.validated(claudeWindowID, snapshot: model.providerQuota(.claude))
        }
        .onChange(of: model.providerQuota(.codex)?.windows.map(\.id)) { _, _ in
            windowID = QuotaWindowSelection.validated(windowID, snapshot: model.providerQuota(.codex))
        }
        .onChange(of: model.providerQuota(.claude)?.windows.map(\.id)) { _, _ in
            claudeWindowID = QuotaWindowSelection.validated(claudeWindowID, snapshot: model.providerQuota(.claude))
        }
        .task(id: "\(cliScanRevision):\(executable)") {
            cliReport = nil
            let path = executable
            let report = await Task.detached(priority: .utility) {
                CodexExecutableResolver.discover(customPath: path)
            }.value
            guard !Task.isCancelled else { return }
            cliReport = report
        }
        .onChange(of: pane) { _, value in UserDefaults.standard.set(value.rawValue, forKey: SettingsPane.defaultsKey) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex Pacer").font(.system(size: 13, weight: .semibold))
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("build.development"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 14)
            ForEach([SettingsPane.general, .appearance, .collapsedBar, .reminders]) { sidebarRow($0) }
            Text(L10n.text("provider.modules")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            ForEach([SettingsPane.codex, .claude, .connections]) { sidebarRow($0) }
            Spacer(minLength: 0)
            sidebarRow(.help).padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
    }

    private func sidebarRow(_ item: SettingsPane) -> some View {
        let selected = pane == item
        let disabledModule = item.provider.map { !moduleEnabled($0) } ?? false
        return Button { pane = item } label: {
            HStack(spacing: 9) {
                SettingsIconTile(symbol: item.symbol, tint: item.tint, glyph: item.glyphColor)
                Text(item.title).font(.system(size: 13)).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if disabledModule {
                    Text(L10n.text("settings.module_off")).font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L10n.text("common.quit")) { model.onQuit?() }
            if let validation {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.text("common.cancel"), action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
            Button(L10n.text(saving ? "common.saving" : languageChanges ? "language.save_restart" : "common.save"), action: { save() })
                .keyboardShortcut(.defaultAction).disabled(saving)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            UpdateSettingsView(updater: updater, automaticallyChecks: $automaticUpdateChecks)
            Section {
                Picker(L10n.text("language.label"), selection: $language) {
                    ForEach(LanguagePreference.allCases, id: \.rawValue) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                if languageChanges { caption(L10n.text("language.restart_hint")) }
            }
            Section {
                Toggle(isOn: $hideProjects) {
                    Text(L10n.text("settings.hide_projects"))
                    Text(L10n.text("settings.hide_projects_sample") + "  →  " + L10n.text("activity.hidden_name"))
                }
            }
        case .appearance:
            SettingsAppearancePane(model: model, appearance: $appearance, displayMode: $displayMode, displayID: $displayID,
                fullscreen: $fullscreen, showInMenuBar: $showInMenuBar, glass: $glass, layout: compactLayout,
                quotaPreview: compactQuotaPreview)
        case .collapsedBar:
            Section {
                CompactLayoutEditor(model: model, layout: $compactLayout, widthSettings: $widthSettings,
                    attached: displayMode.layout(safeAreaTop: model.screenNotchSize.height,
                        hardwareNotchWidth: model.screenNotchSize.width).attached,
                    quotaPreview: compactQuotaPreview)
            }
            let enabled = AgentProvider.allCases.filter { moduleEnabled($0) }
            componentSection(.tasks, enabled: enabled)
            componentSection(.performance, enabled: enabled)
            componentSection(.quota, enabled: enabled)
            componentSection(.warnings, enabled: enabled)
        case .reminders:
            // Warnings stay in the collapsed bar while their condition lasts;
            // reminders mark a moment. Both are chosen here and nowhere else.
            Section(L10n.text("reminders.section.warnings")) {
                warningRow(.fiveHour) { FiveHourAlertGlyph(alert: .low(12), tint: AgentProvider.codex.tint) }
                warningRow(.ssh) { Image(systemName: StatusSymbols.sshWarning).font(.system(size: 11, weight: .semibold)) }
                warningRow(.quotaDelay) { Image(systemName: StatusSymbols.freshness).font(.system(size: 11, weight: .semibold)) }
            }
            Section(L10n.text("reminders.section.island")) {
                reminderRow("reminders.low_quota", isOn: $lowReminder) {
                    Text("12%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                reminderRow("reminders.waiting", isOn: $inputReminder) {
                    ActivityBadge(activity: .init(core: .count(1), activeCount: 1, orbit: [:], attention: .input))
                }
                reminderRow("reminders.completion", isOn: $completionReminder) {
                    ActivityBadge(activity: .init(core: .symbol(StatusSymbols.complete), activeCount: 0, orbit: [:], ending: .completed(.codex)))
                }
                reminderRow("settings.system_notifications", isOn: $systemNotifications) {
                    Image(systemName: "bell.badge").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            Section {
                Picker(L10n.text("reminders.retention"), selection: $completedRetention) {
                    Text(L10n.text("settings.five_minutes")).tag(5)
                    Text(L10n.text("settings.fifteen_minutes")).tag(15)
                    Text(L10n.text("settings.thirty_minutes")).tag(30)
                    Text(L10n.text("settings.one_hour")).tag(60)
                    Text(L10n.text("settings.four_hours")).tag(240)
                    Text(L10n.text("settings.until_clicked")).tag(0)
                }
            }
        case .codex, .claude:
            if let provider = pane.provider { providerPane(provider) }
        case .help:
            SettingsHelpPane()
        case .connections:
            SettingsConnectionsPane(model: model, monitorSSH: $monitorSSH, monitorRemoteControl: $monitorRemoteControl,
                additionalSSHHosts: $claudeSSHHosts, codexEnabled: moduleEnabled(.codex), claudeEnabled: moduleEnabled(.claude),
                sshPending: claudeSSHHostsChanged || monitorSSH != model.monitorsSSH)
        }
    }

    @ViewBuilder private func providerPane(_ provider: AgentProvider) -> some View {
        Section {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: provider.glyph, tint: provider.tint, glyph: Color.black.opacity(0.72), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                    Text(L10n.text(model.providerDetected(provider) ? "provider.detected" : "provider.not_detected") +
                        (moduleMode(provider) == .automatic ? " · " + L10n.text("provider.automatic") : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(provider.displayName, isOn: moduleBinding(provider)).labelsHidden().toggleStyle(.switch)
            }
            .padding(.vertical, 2)
        } footer: {
            if moduleMode(provider) != .automatic {
                HStack {
                    Spacer()
                    Button(L10n.text("provider.restore_automatic")) {
                        if provider == .codex { modules.codexMode = .automatic } else { modules.claudeMode = .automatic }
                    }.font(.system(size: 11)).buttonStyle(.link)
                }
            }
        }
        if moduleEnabled(provider) {
            localSection(provider)
            if model.enabledProviders.contains(provider) { quotaHistorySection(provider) }
        }
    }

    /// Both modules read the same way: what was found on this Mac, a button only
    /// when something needs the user, and path overrides folded away.
    private func localSection(_ provider: AgentProvider) -> some View {
        Section(L10n.text("provider.section.local")) {
            if provider == .codex { codexCLIRow } else { claudeMonitoringRow; claudeAccountRow }
            DisclosureGroup(L10n.text("provider.custom_locations"), isExpanded: Binding(
                get: { expandedLocations.contains(provider) },
                set: { if $0 { expandedLocations.insert(provider) } else { expandedLocations.remove(provider) } })) {
                VStack(alignment: .leading, spacing: 10) {
                    if provider == .codex { codexLocations } else { claudeLocations }
                }.padding(.top, 6)
            }
        }
    }

    private func statusRow<Action: View>(_ title: String, state: String, tint: Color, help: String? = nil,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(state).foregroundStyle(tint == .orange ? Color.orange : Color.secondary)
            action()
        }
        .help(help ?? "")
    }

    private var codexCLIRow: some View {
        let report = cliReport
        let (tint, state): (Color, String) = report == nil ? (.secondary, L10n.text("provider.state.searching")) :
            report?.selected != nil ? (.green, L10n.text("provider.state.found")) : (.orange, L10n.text("provider.state.not_found"))
        return VStack(alignment: .leading, spacing: 4) {
            statusRow("Codex CLI", state: state, tint: tint, help: report?.selected?.url.path) {
                if report != nil, report?.selected == nil {
                    Button(L10n.text("settings.rescan")) { cliScanRevision += 1 }
                }
            }
            if let issue = report?.issue, report?.selected == nil { caption(issue) }
        }
    }

    private var claudeMonitoringRow: some View {
        let (tint, state): (Color, String) = switch model.claudeLocalSetup {
        case .ready: (.green, L10n.text("provider.state.ready"))
        case .checking, .configuring: (.secondary, L10n.text("provider.state.configuring"))
        case .missingHome: (.secondary, L10n.text("provider.state.no_home"))
        case .failed: (.orange, L10n.text("provider.state.failed"))
        }
        return statusRow(L10n.text("provider.monitoring"), state: state, tint: tint,
                         help: model.claudeLocalSetup == .failed ? L10n.text("claude.monitoring_setup_failed") : nil) {
            if model.claudeLocalSetup == .failed {
                Button(L10n.text("connections.retry")) { model.retryClaudeLocalSetup() }
            }
        }
    }

    /// Sign-in reads as a status. A button appears only when Claude needs the
    /// user; switching accounts otherwise waits in the row's menu.
    private var claudeAccountRow: some View {
        let workspace = model.claudeNeedsOrganizationSelection, signedOut = model.claudeConnectionNeeded && !workspace
        let signedIn = !model.claudeConnectionNeeded && model.claudeQuotaSource != nil
        let (tint, key): (Color, String) =
            workspace ? (.orange, "claude.account.workspace_needed") :
            signedOut ? (.orange, "claude.account.signed_out") :
            signedIn ? (.green, "claude.account.signed_in") :
            model.providerRefreshing(.claude) ? (.secondary, "claude.account.checking") : (.secondary, "claude.account.unavailable")
        let unavailable = model.providerRefreshing(.claude) || resolvedClaudeHome != model.claudeHome.path || !model.isModuleEnabled(.claude)
        return statusRow(L10n.text("claude.account"), state: L10n.text(key), tint: tint,
                         help: signedIn ? model.claudeQuotaSource?.label : nil) {
            Group {
                if workspace {
                    Button(L10n.text("claude.quota.choose_workspace")) { model.chooseClaudeOrganization() }
                        .help(L10n.text("claude.quota.choose_workspace_help"))
                } else if signedOut {
                    Button(L10n.text("claude.quota.connect")) { model.signInClaudeQuota() }
                        .help(L10n.text("claude.quota.connect_help"))
                } else {
                    Menu {
                        Button(L10n.text(signedIn ? "claude.account.switch" : "claude.quota.connect")) { model.signInClaudeQuota() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L10n.text("claude.account.options"))
                }
            }
            .disabled(unavailable)
        }
    }

    @ViewBuilder private var codexLocations: some View {
        HStack {
            TextField(L10n.text("settings.cli_path"), text: $executable, prompt: Text(L10n.text("settings.auto_discovery")))
            if let report = cliReport, report.candidates.count > 1 {
                Menu(L10n.text("settings.other_locations")) {
                    ForEach(report.candidates) { candidate in
                        Button(L10n.text("settings.cli_candidate", candidate.source, candidate.url.path)) { executable = candidate.url.path }
                    }
                }.fixedSize()
            }
            Button(L10n.text("common.choose")) { choose(directory: false) }
        }
        HStack {
            TextField(L10n.text("settings.codex_home"), text: $home, prompt: Text(L10n.text("settings.home_placeholder")))
            Button(L10n.text("common.choose")) { choose(directory: true) }
        }
        if executable != (UserDefaults.standard.string(forKey: "codexExecutable") ?? "") ||
            home != (UserDefaults.standard.string(forKey: "codexHome") ?? "") {
            caption(L10n.text("settings.applies_on_save"))
        }
    }

    @ViewBuilder private var claudeLocations: some View {
        HStack {
            TextField(L10n.text("provider.claude_home"), text: $claudeHome, prompt: Text("~/.claude"))
            Button(L10n.text("common.choose")) { chooseClaudeHome() }
        }
        if resolvedClaudeHome != model.claudeHome.path { caption(L10n.text("settings.applies_on_save")) }
    }

    /// One grouped section per component category. Each component is a single
    /// row (a stable row count keeps the table-backed Form valid); options that
    /// only matter while it is shown sit inside that row, under its title.
    private func componentSection(_ group: CompactIslandLayout.Group, enabled: [AgentProvider]) -> some View {
        Section {
            ForEach(group.components.filter { $0.isAvailable(for: Set(enabled)) }) { component in
                VStack(alignment: .leading, spacing: 8) {
                    CompactComponentToggle(component: component, layout: $compactLayout)
                    componentOptions(component)
                }
            }
            if group == .quota {
                if enabled.isEmpty {
                    caption(L10n.text("layout.no_quota_providers"))
                } else if compactLayout.components.contains(where: { group.components.contains($0) }) {
                    if enabled.contains(.codex) { quotaWindowPicker(.codex, selection: $windowID) }
                    if enabled.contains(.claude) { quotaWindowPicker(.claude, selection: $claudeWindowID) }
                }
            }
        } header: {
            Text(group.label)
        }
    }
    /// The value choice follows the quota value, or its label when the value is hidden.
    @ViewBuilder private func componentOptions(_ component: CompactIslandLayout.Component) -> some View {
        let shown = compactLayout.components
        if component == .warnings, shown.contains(.warnings) {
            Button(L10n.text("layout.warnings_choose")) { pane = .reminders }
                .buttonStyle(.link).font(.system(size: 12))
                .padding(.leading, CompactComponentToggle.optionInset)
        } else if component == .activity, shown.contains(.activity) {
            Picker(L10n.text("layout.single_task"), selection: $singleTask) {
                ForEach(ActivityBadgeSingleTask.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .padding(.leading, CompactComponentToggle.optionInset)
        } else if (component == .quota && shown.contains(.quota)) ||
                    (component == .quotaLabel && shown.contains(.quotaLabel) && !shown.contains(.quota)) {
            Picker(L10n.text("settings.compact_metric"), selection: $metric) {
                Text(L10n.text("settings.remaining_quota")).tag("remaining")
                Text(L10n.text("settings.pace_percentage")).tag("pace")
            }
            .padding(.leading, CompactComponentToggle.optionInset)
        }
    }

    private var compactQuotaPreview: CompactQuotaPreview {
        CompactQuotaPreview(providers: AgentProvider.allCases.filter { moduleEnabled($0) },
            metric: metric, windowIDs: [.codex: windowID, .claude: claudeWindowID], singleTask: singleTask,
            warnings: compactLayout.warnings)
    }

    /// Each reminder shows the mark it puts on the island.
    private func reminderRow<Sample: View>(_ key: String, isOn: Binding<Bool>, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 12) {
            IslandSampleSwatch(width: IslandSampleSwatch<EmptyView>.compactWidth, content: sample)
            Toggle(L10n.text(key), isOn: isOn)
        }
    }

    /// Turning a warning on also brings the warnings slot back if it was removed
    /// from the bar, so this switch alone decides what shows.
    private func warningRow<Sample: View>(_ warning: CompactIslandLayout.Warning, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 12) {
            IslandSampleSwatch(width: IslandSampleSwatch<EmptyView>.compactWidth, content: sample)
            Toggle(warning.label, isOn: Binding(get: { compactLayout.warnings.contains(warning) && compactLayout.components.contains(.warnings) },
                set: { on in
                    if on, !compactLayout.components.contains(.warnings) {
                        // A removed slot comes back with only the warning just chosen.
                        compactLayout.warnings = [warning]
                        compactLayout.move(.warnings, to: .trailing, before: compactLayout.trailing.first)
                    } else if on { compactLayout.warnings.insert(warning) }
                    else { compactLayout.warnings.remove(warning) }
                }))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func quotaHistorySection(_ provider: AgentProvider) -> some View {
        Section(L10n.text("settings.quota_history", provider.displayName)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let source = model.providerSourceText(provider) { Text(source).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Text(model.providerFreshnessText(provider, period: .weekly)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            if model.providerQuotaIsStale(provider, period: .weekly) || model.providerQuotaError(provider) != nil {
                Label(L10n.text("common.not_updated"), systemImage: StatusSymbols.freshness)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = model.providerQuotaError(provider) {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = model.providerQuota(provider) {
                if let cycle = model.providerCurrentCycle(provider) {
                    QuotaCycleChart(data: QuotaChartData(cycle: cycle, resetCredits: snapshot.resetCredits, now: model.now),
                        accent: provider.tint, referenceColor: .primary).equatable().padding(.vertical, 8)
                } else if model.providerWindow(provider, period: .weekly) != nil {
                    Text(L10n.text("quota.waiting_sample")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !snapshot.buckets.isEmpty {
                    DisclosureGroup(L10n.text("settings.quota_details")) {
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 12) {
                                if snapshot.buckets.count > 1 {
                                    Text(bucket.name ?? bucket.id).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                }
                                ForEach(bucket.windows) { window in
                                    QuotaWindowView(window: window, now: model.now,
                                        allowPace: !snapshot.isStale(at: model.now) && model.providerQuotaError(provider) == nil && window.resetsAt.map({ $0 > model.now }) == true,
                                        accent: provider.tint, secondary: .secondary, referenceColor: .primary)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                }
                if provider == .codex || snapshot.credits != nil || snapshot.resetCredits != nil {
                    AccountUsageView(snapshot: snapshot, now: model.now, showsExpiryDetails: Binding(
                        get: { showsResetExpiryDetails.contains(provider) },
                        set: { if $0 { showsResetExpiryDetails.insert(provider) } else { showsResetExpiryDetails.remove(provider) } }))
                }
            } else {
                Text(model.providerRefreshing(provider) ? L10n.text("quota.loading") : L10n.text("quota.not_connected", provider.displayName))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let warning = model.providerHistoryWarning(provider) {
                Label(L10n.text("quota.chart_warning"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).help(warning)
            }
            HStack(spacing: 12) {
                Button(L10n.text(model.providerRefreshing(provider) ? "common.retrying" : "common.refresh")) {
                    model.retryQuotaConnection(for: provider)
                }
            }.font(.system(size: 11)).disabled(model.providerRefreshing(provider))
        }
    }

    private func quotaWindowPicker(_ provider: AgentProvider, selection: Binding<String>) -> some View {
        let snapshot = model.providerQuota(provider)
        return Picker(L10n.text("provider.window_selection", provider.displayName), selection: selection) {
            Text(L10n.text("settings.auto_weekly")).tag("auto")
            if selection.wrappedValue != "auto", !(snapshot?.windows ?? []).contains(where: { $0.id == selection.wrappedValue }) {
                Text(L10n.text("settings.saved_quota_window")).tag(selection.wrappedValue)
            }
            ForEach(snapshot?.buckets ?? []) { bucket in
                ForEach(bucket.windows) { window in
                    Text(window.label + ((snapshot?.buckets.count ?? 0) > 1 ? " · " + (bucket.name ?? bucket.id) : "")).tag(window.id)
                }
            }
        }
    }

    private func moduleMode(_ provider: AgentProvider) -> ProviderModuleMode {
        provider == .codex ? modules.codexMode : modules.claudeMode
    }
    private func moduleEnabled(_ provider: AgentProvider) -> Bool {
        switch moduleMode(provider) {
        case .automatic: return model.providerDetected(provider)
        case .enabled: return true
        case .disabled: return false
        }
    }
    private func moduleBinding(_ provider: AgentProvider) -> Binding<Bool> {
        Binding(get: { moduleEnabled(provider) }, set: { value in
            if provider == .codex { modules.codexMode = value ? .enabled : .disabled }
            else { modules.claudeMode = value ? .enabled : .disabled }
        })
    }
    private var resolvedClaudeHome: String {
        let configured = claudeHome.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = configured.isEmpty
            ? (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") : configured
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    private func chooseClaudeHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = L10n.text("provider.choose_claude_home")
        if panel.runModal() == .OK, let path = panel.url?.path { claudeHome = path }
    }
    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = directory ? L10n.text("settings.choose_home") : L10n.text("settings.choose_cli")
        if panel.runModal() == .OK, let path = panel.url?.path {
            if directory { home = path } else { executable = path }
        }
    }
    private func save() {
        if languageChanges && updater.sessionInProgress {
            validation = L10n.text("language.update_busy"); return
        }
        let shouldRelaunch = languageChanges
        let cli = CodexExecutableResolver.normalize(executable)
        let directory = home.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeDirectory = claudeHome.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = claudeSSHHosts.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if moduleEnabled(.codex), !cli.isEmpty {
            if let issue = CodexExecutableResolver.discover(customPath: cli).issue {
                validation = issue; return
            }
        }
        if moduleEnabled(.codex), !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                validation = L10n.text("settings.invalid_home"); return
            }
        }
        if moduleEnabled(.claude), !claudeDirectory.isEmpty {
            var isDirectory: ObjCBool = false
            guard resolvedClaudeHome.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: resolvedClaudeHome, isDirectory: &isDirectory), isDirectory.boolValue else {
                validation = L10n.text("provider.invalid_claude_home"); return
            }
        }
        guard !moduleEnabled(.claude) || !monitorSSH || aliases.allSatisfy({ $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil }) else {
            validation = L10n.text("provider.invalid_ssh_hosts"); return
        }
        widthSettings = widthSettings.normalized
        saving = true
        Task { @MainActor in
            let allowed = systemNotifications ? await NotificationDelivery.requestPermission() : false
            let requestedSystem = systemNotifications
            let defaults = UserDefaults.standard
            let sourceChanged = cli != (defaults.string(forKey: "codexExecutable") ?? "") || directory != (defaults.string(forKey: "codexHome") ?? "") || monitorSSH != model.monitorsSSH || monitorRemoteControl != model.monitorsRemoteControl
            defaults.set(monitorSSH, forKey: "monitorSSH")
            defaults.set(monitorRemoteControl, forKey: "monitorRemoteControl")
            defaults.set(cli, forKey: "codexExecutable")
            defaults.set(directory, forKey: "codexHome")
            modules.save(to: defaults)
            defaults.set(claudeDirectory, forKey: "claudeHome")
            defaults.set(aliases.joined(separator: "\n"), forKey: "claudeSSHHosts")
            displayMode.save(to: defaults)
            widthSettings.save(to: defaults)
            compactLayout.save(to: defaults)
            defaults.removeObject(forKey: "performanceRefreshMode")
            defaults.removeObject(forKey: "quotaDashboardPeriod")
            defaults.set(appearance.rawValue, forKey: "islandAppearance")
            glass.save()
            defaults.set(fullscreen, forKey: "showInFullscreen")
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            defaults.set(displayID, forKey: "displayID")
            defaults.set(metric, forKey: "compactMetric")
            defaults.set(singleTask.rawValue, forKey: ActivityBadgeSingleTask.defaultsKey)
            defaults.set(windowID, forKey: "quotaWindowID")
            defaults.set(claudeWindowID, forKey: "claudeQuotaWindowID")
            defaults.set(lowReminder, forKey: "lowQuotaReminder")
            defaults.set(inputReminder, forKey: "inputReminder")
            defaults.set(completionReminder, forKey: "completionReminder")
            defaults.set(completedRetention, forKey: "completedRetentionMinutes")
            defaults.set(allowed, forKey: "systemNotifications")
            defaults.set(hideProjects, forKey: "hideProjects")
            language.save(to: defaults)
            updater.setAutomaticallyChecks(automaticUpdateChecks)
            model.applySettings(sourceChanged: sourceChanged)
            saving = false
            systemNotifications = allowed
            if requestedSystem && !allowed {
                validation = L10n.text("settings.notification_denied")
            } else if shouldRelaunch {
                if let relaunch = model.onRelaunch {
                    if let reason = relaunch() { validation = L10n.text("language.restart_failed", reason) }
                } else {
                    validation = L10n.text("language.restart_failed", L10n.text("language.missing_helper"))
                }
            } else { onClose() }
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, collapsedBar, reminders, codex, claude, connections, help
    static let defaultsKey = "settingsPane"
    var id: String { rawValue }
    var provider: AgentProvider? { self == .codex ? .codex : self == .claude ? .claude : nil }
    var title: String {
        switch self {
        case .general: return L10n.text("settings.pane.general")
        case .appearance: return L10n.text("settings.pane.appearance")
        case .collapsedBar: return L10n.text("settings.pane.collapsed")
        case .reminders: return L10n.text("settings.reminders")
        case .codex: return AgentProvider.codex.displayName
        case .claude: return AgentProvider.claude.displayName
        case .connections: return L10n.text("settings.pane.connections")
        case .help: return L10n.text("settings.pane.help")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .collapsedBar: return "rectangle.topthird.inset.filled"
        case .reminders: return "bell.badge.fill"
        case .codex: return AgentProvider.codex.glyph
        case .claude: return AgentProvider.claude.glyph
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .help: return "questionmark"
        }
    }
    var tint: Color {
        switch self {
        case .general: return Color(white: 0.52)
        case .appearance: return Color(red: 0.44, green: 0.4, blue: 0.96)
        case .collapsedBar: return Color(red: 0.2, green: 0.22, blue: 0.27)
        case .reminders: return Color(red: 1, green: 0.3, blue: 0.29)
        case .codex: return AgentProvider.codex.tint
        case .claude: return AgentProvider.claude.tint
        case .connections: return Color(red: 0.16, green: 0.5, blue: 1)
        case .help: return Color(white: 0.52)
        }
    }
    var glyphColor: Color { provider == nil ? .white : Color.black.opacity(0.72) }
}

/// System Settings style navigation tile.
private struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var glyph: Color = .white
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(glyph)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}
