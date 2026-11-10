import PacerMacSupport
import AppKit
import SwiftUI
import PacerCore

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var notificationPreference: SystemNotificationPreference
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    let onClose: () -> Void
    var onShowWelcome: () -> Void = {}
    /// The app delegate shows or hides the Dock icon as this changes.
    var onDockIconChange: (DockIconPreference) -> Void = { _ in }
    @State private var dockIcon = DockIconPreference.load()
    @State private var executable = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
    @State private var home = UserDefaults.standard.string(forKey: "codexHome") ?? ""
    @State private var modules = ProviderModules.load()
    @State private var claudeHome = UserDefaults.standard.string(forKey: "claudeHome") ?? ""
    @State private var deepseekHome = UserDefaults.standard.string(forKey: "deepseekHome") ?? ""
    @State private var deepseekSource = DeepSeekBalanceSource.load()
    /// Nil follows the rules shown in the empty field.
    @State private var deepseekLowBalance = IslandModel.deepseekLowLine(in: .standard)
    @State private var deepseekSpikeLimit = DeepSeekBudgetSettings.amount(IslandModel.deepseekSpikeLimitKey, in: .standard)
    @State private var deepseekPanelStyle = DeepSeekPanelStyle.load()
    @State private var deepseekBudgets = DeepSeekBudgetSettings.load()
    /// "" follows the modules; a provider or "none" was chosen.
    @State private var quotaRings = QuotaRingSlot.allCases.map { UserDefaults.standard.string(forKey: $0.defaultsKey) ?? "" }
    @AppStorage(IslandModel.deepseekTurnCostKey) private var showsDeepSeekTurnCost = true
    @AppStorage(IslandModel.deepseekSpeedSourceKey) private var deepseekSpeedSource = DeepSeekSpeedSource.local.rawValue
    @State private var showsResetExpiryDetails: Set<AgentProvider> = []
    @State private var displayMode = IslandDisplayMode.load()
    /// Nil until chosen, so an unrelated change never stores the center.
    @State private var position = IslandPosition.saved()
    @State private var compactLayout = CompactIslandLayout.load()
    @State private var componentOptions = CompactComponentOptions.load()
    @State private var barSize = CompactBarSize.load()
    @State private var appearance = IslandAppearance.stored
    @State private var theme = AppTheme(defaults: .standard)
    @State private var accent = PacerAccent(defaults: .standard)
    @State private var quotaStyle = ExpandedQuotaStyle.load()
    @State private var fullscreen = UserDefaults.standard.bool(forKey: "showInFullscreen")
    @State private var positionPerDisplay = IslandScreenMemory.isEnabled(in: .standard)
    @State private var displayID = UserDefaults.standard.integer(forKey: "displayID")
    @State private var metric = UserDefaults.standard.string(forKey: "compactMetric") ?? "remaining"
    @State private var singleTask = ActivityBadgeSingleTask()
    @State private var windowID = UserDefaults.standard.string(forKey: "quotaWindowID") ?? "auto"
    @State private var claudeWindowID = UserDefaults.standard.string(forKey: "claudeQuotaWindowID") ?? "auto"
    @State private var completedRetention = UserDefaults.standard.object(forKey: "completedRetentionMinutes") as? Int ?? 30
    @State private var hideProjects = UserDefaults.standard.bool(forKey: "hideProjects")
    @State private var monitorSSH = UserDefaults.standard.object(forKey: "monitorSSH") == nil || UserDefaults.standard.bool(forKey: "monitorSSH")
    @State private var monitorRemoteControl = UserDefaults.standard.object(forKey: "monitorRemoteControl") == nil || UserDefaults.standard.bool(forKey: "monitorRemoteControl")
    /// Shared with the update note, which can change them while this is open.
    @AppStorage(IslandModel.showsEmbeddedClaudeSessionsKey) private var showEmbeddedClaudeSessions = true
    @AppStorage(IslandModel.showsEmbeddedCodexSessionsKey) private var showEmbeddedCodexSessions = true
    @AppStorage(IslandModel.showsClaudeCloudProjectsKey) private var showClaudeCloudProjects = true
    @AppStorage(IslandModel.claudeProgressRingKey) private var claudeProgressRing = true
    @AppStorage(IslandModel.codexProgressRingKey) private var codexProgressRing = true
    @AppStorage(IslandModel.deepseekProgressRingKey) private var deepseekProgressRing = true
    @AppStorage(IslandModel.showsAppButtonsKey) private var showsAppButtons = true
    @State private var language = LanguagePreference.load()
    @State private var languageError: String?
    /// Text settings commit on Return, focus loss, a chooser or window close;
    /// an invalid value keeps the last valid one and explains why here.
    @State private var textIssues: [TextSetting: String] = [:]
    @FocusState private var focusedText: TextSetting?
    @State private var applyTask: Task<Void, Never>?
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
    @State private var pane = SettingsPane.load()
    /// A row a link elsewhere asked for, scrolled into view when its pane opens.
    @State private var scrollTarget: String?
    private static let gaugeAnchor = SettingsCollapsedBarPane.inspectorAnchor
    /// The component whose settings the Collapsed Bar page shows.
    @State private var collapsedSelection: CompactIslandLayout.Component?
    private var languageChanges: Bool { language.resolved() != L10n.language }

    var body: some View {
        HStack(spacing: 0) {
            MainWindowSidebar(selection: $pane, isDisabled: { $0.provider.map { !moduleEnabled($0) } ?? false },
                needsAttention: needsAttention, updateVersion: updater.flow.available?.version)
                .background(SidebarMaterial())
            Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 560, idealHeight: 660)
        .environment(\.locale, L10n.locale)
        .pacerAccent(accent)
        .onAppear {
            automaticUpdateChecks = updater.automaticallyChecks
            launchAtLogin.refresh()
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
        // Settings apply as they change, like System Settings; there is no Save.
        .onChange(of: liveSettings) { _, _ in scheduleApply() }
        .onChange(of: theme) { _, value in value.apply() }
        // A drag or Return to Top Center saved the display and position itself.
        .onChange(of: model.placementRevision) { _, _ in
            displayMode = IslandDisplayMode.load()
            position = IslandPosition.saved()
            displayID = UserDefaults.standard.integer(forKey: "displayID")
        }
        .onChange(of: focusedText) { previous, _ in if let previous { commit(previous) } }
        .onChange(of: automaticUpdateChecks) { _, value in updater.setAutomaticallyChecks(value) }
        .onChange(of: language) { _, value in value.save(to: .standard); languageError = nil }
        .onChange(of: dockIcon) { _, value in value.save(); onDockIconChange(value) }
        .onDisappear {
            if let focusedText { commit(focusedText) }
            if applyTask != nil { applyNow() }
        }
    }

    /// Overview and History lay out their own cards; every other page is one
    /// centered column of cards under its header.
    private var detail: some View {
        Group {
            switch pane {
            case .overview: OverviewPane(model: model, updater: updater, attention: attentionItems, open: { pane = $0 })
            case .history: HistoryPane(model: model)
            default:
                ScrollViewReader { proxy in
                    MainPage {
                        pageHeader
                        paneContent
                    }
                    .task {
                        guard let target = scrollTarget else { return }
                        scrollTarget = nil
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
        }
        .id(pane)
        .background(MainPalette.page)
    }

    @ViewBuilder private var pageHeader: some View {
        if let provider = pane.provider {
            providerHeader(provider)
        } else {
            switch pane {
            case .remote: PageHeader(title: pane.title, subtitle: SettingsConnectionsPane.summaryText(model))
            case .notifications: PageHeader(title: pane.title, subtitle: L10n.text("main.subtitle.notifications"))
            case .collapsedBar: PageHeader(title: pane.title, subtitle: L10n.text("main.collapsed.subtitle")) {
                Button(L10n.text("common.restore_defaults")) { compactLayout = .standard }.buttonStyle(.main)
            }
            default: PageHeader(title: pane.title)
            }
        }
    }

    private func providerHeader(_ provider: AgentProvider) -> some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: provider.glyph, tint: provider.shade(light: false), glyph: Color.black.opacity(0.72), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Text(L10n.text(model.providerDetected(provider) ? "provider.detected" : "provider.not_detected") +
                        (moduleMode(provider) == .automatic ? " · " + L10n.text("provider.automatic") : ""))
                    if moduleMode(provider) != .automatic {
                        Button(L10n.text("provider.restore_automatic")) { modules.setMode(.automatic, for: provider) }
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(provider.displayName, isOn: moduleBinding(provider)).labelsHidden().toggleStyle(.switch)
        }
    }

    /// What Claude needs from the user, if anything, as its state's text key.
    private var claudeAttentionKey: String? {
        guard moduleEnabled(.claude) else { return nil }
        if model.claudeLocalSetup == .failed { return "provider.state.failed" }
        if model.claudeNeedsOrganizationSelection { return "claude.account.workspace_needed" }
        if model.claudeConnectionNeeded { return "claude.account.signed_out" }
        return nil
    }

    private func needsAttention(_ pane: SettingsPane) -> Bool {
        switch pane {
        case .claude: claudeAttentionKey != nil
        case .codex: moduleEnabled(.codex) && cliReport.map { $0.selected == nil } == true
        case .remote: SettingsConnectionsPane.problemCount(model) > 0
        default: false
        }
    }

    private var attentionItems: [OverviewAttention] {
        var items: [OverviewAttention] = []
        if let key = claudeAttentionKey {
            let (action, perform): (String, () -> Void) = switch key {
            case "provider.state.failed": (L10n.text("connections.retry"), { model.retryClaudeLocalSetup() })
            case "claude.account.workspace_needed": (L10n.text("claude.quota.choose_workspace"), { model.chooseClaudeOrganization() })
            default: (L10n.text("claude.quota.connect"), { model.signInClaudeQuota() })
            }
            items.append(.init(id: "claude", title: AgentProvider.claude.displayName + " · " + L10n.text(key),
                detail: L10n.text("main.attention.quota_waits"), action: action, perform: perform))
        }
        if needsAttention(.codex) {
            items.append(.init(id: "codex", title: "Codex CLI · " + L10n.text("provider.state.not_found"),
                detail: L10n.text("main.attention.codex_cli"), action: L10n.text("main.overview.open"), perform: { pane = .codex }))
        }
        let problems = SettingsConnectionsPane.problemCount(model)
        if problems > 0 {
            items.append(.init(id: "remote", title: L10n.text("main.pane.remote"),
                detail: L10n.text(problems == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying", problems),
                action: L10n.text("main.overview.open"), perform: { pane = .remote }))
        }
        return items
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            MainCard(title: L10n.text("main.section.startup")) {
                CardToggle(title: L10n.text("settings.open_at_login"),
                    isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.needsApproval {
                    CardRow(title: L10n.text("settings.login_item_approval")) {
                        Button(L10n.text("settings.login_item_open")) { launchAtLogin.openSystemSettings() }.buttonStyle(.main)
                    }
                    .foregroundStyle(MainPalette.attention)
                }
                if let failure = launchAtLogin.failure { warning(failure) }
                CardPicker(title: L10n.text("main.dock"), info: L10n.text("main.dock_info"), selection: $dockIcon,
                           options: DockIconPreference.allCases.map { ($0, $0.label) })
            }
            MainCard(title: L10n.text("main.section.language")) {
                CardPicker(title: L10n.text("language.label"), selection: $language,
                           options: LanguagePreference.allCases.map { ($0, $0.label) })
                if languageChanges {
                    CardRow(title: L10n.text("language.restart_hint")) {
                        Button(L10n.text("language.restart_now")) { relaunchForLanguage() }.buttonStyle(.mainProminent)
                    }
                }
                if let languageError { warning(languageError) }
            }
            MainCard(title: L10n.text("main.privacy")) {
                CardToggle(title: L10n.text("settings.hide_projects"), info: L10n.text("settings.hide_projects_help"), isOn: $hideProjects)
            }
        case .appearance:
            SettingsAppearancePane(model: model, theme: $theme, appearance: $appearance, accent: $accent, barSize: $barSize, displayMode: $displayMode, position: $position,
                displayID: $displayID, fullscreen: $fullscreen, positionPerDisplay: $positionPerDisplay, quotaStyle: $quotaStyle, deepseekPanelStyle: $deepseekPanelStyle,
                showsAppButtons: $showsAppButtons,
                deepseekAlone: AgentProvider.allCases.filter { moduleEnabled($0) } == [.deepseek])
        case .collapsedBar:
            SettingsCollapsedBarPane(model: model, layout: $compactLayout, selection: $collapsedSelection, singleTask: $singleTask,
                metric: $metric, windowID: $windowID, claudeWindowID: $claudeWindowID, quotaRings: $quotaRings,
                options: $componentOptions, deepseekBudgets: $deepseekBudgets,
                providers: AgentProvider.allCases.filter { moduleEnabled($0) }, openNotifications: { pane = .notifications })
        case .notifications:
            SettingsNotificationsPane(model: model, notificationPreference: notificationPreference, layout: $compactLayout,
                retention: $completedRetention, lowBalance: $deepseekLowBalance, spikeLimit: $deepseekSpikeLimit,
                providers: AgentProvider.allCases.filter { moduleEnabled($0) }, openDeepSeek: { pane = .deepseek })
        case .codex, .claude, .deepseek:
            if let provider = pane.provider { providerPane(provider) }
        case .remote:
            SettingsConnectionsPane(model: model, monitorSSH: $monitorSSH, monitorRemoteControl: $monitorRemoteControl,
                codexEnabled: moduleEnabled(.codex), claudeEnabled: moduleEnabled(.claude))
        case .about:
            SettingsAboutPane(updater: updater, automaticallyChecks: $automaticUpdateChecks, launchAtLogin: launchAtLogin,
                onShowWelcome: onShowWelcome)
        case .support:
            SettingsSupportPane()
        case .overview, .history:
            EmptyView()
        }
    }

    /// A service page: its state, then what it shows, with file locations
    /// folded away. The quota trend lives on History.
    @ViewBuilder private func providerPane(_ provider: AgentProvider) -> some View {
        if !moduleEnabled(provider) {
            MainCard { CardRow(title: L10n.text("main.module_off_hint")) }
        } else if provider == .deepseek {
            SettingsDeepSeekSections(model: model, balanceSource: $deepseekSource, budgets: $deepseekBudgets,
                // Like Codex, the switch applies at once, so turning it off and quitting still removes the entry.
                showsTurnCost: $showsDeepSeekTurnCost, showsProgressRing: Binding(get: { deepseekProgressRing }, set: { value in
                    deepseekProgressRing = value
                    model.syncDeepSeekProgressSwitch()
                }),
                speedSource: $deepseekSpeedSource,
                ringSlot: model.deepseekValueShowsBudget ? QuotaRingSlot(rawValue: model.compactRingProviders.firstIndex(of: .deepseek) ?? 0) : nil,
                openCollapsedBar: {
                    collapsedSelection = .quotaGauge
                    scrollTarget = Self.gaugeAnchor
                    pane = .collapsedBar
                }, openHistory: { pane = .history }, home: $deepseekHome, homeIssue: textIssues[.deepseekHome],
                commitHome: { commit(.deepseekHome) }, chooseHome: chooseDeepSeekHome)
        } else {
            MainCard(title: L10n.text("main.section.status")) {
                if provider == .codex { codexCLIRow } else { claudeMonitoringRow; claudeAccountRow }
                if model.enabledProviders.contains(provider) {
                    ProviderQuotaRow(model: model, provider: provider, openHistory: { pane = .history })
                }
            }
            MainCard(title: L10n.text("main.section.display")) {
                if provider == .codex {
                    CardToggle(title: L10n.text("main.embedded"), info: L10n.text("main.info.codex_embedded"), isOn: $showEmbeddedCodexSessions)
                    let setup = codexProgressRing ? model.codexProgressSetup : nil
                    let setupMessage = setup.map { status in
                        switch status {
                        case .settingUp, .ready: L10n.text("codex.progress_setup.mac." + status.rawValue)
                        case .missingCLI, .conflict, .failed: L10n.text("codex.progress_setup." + status.rawValue)
                        }
                    }
                    ProgressRingToggle(info: L10n.text("codex.progress_ring_help"), isOn: Binding(get: { codexProgressRing }, set: { value in
                            codexProgressRing = value
                            model.syncCodexProgressSwitch()
                        }),
                        status: setupMessage,
                        canRetry: setup == .failed || setup == .missingCLI || setup == .conflict,
                        retry: { model.syncCodexProgressSwitch(force: true) })
                } else {
                    CardToggle(title: L10n.text("main.claude.cloud"), info: L10n.text("main.info.claude_cloud"), isOn: $showClaudeCloudProjects)
                    CardToggle(title: L10n.text("main.embedded"), info: L10n.text("main.info.claude_embedded"), isOn: $showEmbeddedClaudeSessions)
                    CardToggle(title: L10n.text("main.claude.ring"), info: L10n.text("main.info.claude_ring"), isOn: $claudeProgressRing)
                }
            }
            MainCard {
                CardDisclosure(title: L10n.text("provider.custom_locations"), summary: locationSummary(provider),
                    isExpanded: Binding(get: { expandedLocations.contains(provider) },
                        set: { if $0 { expandedLocations.insert(provider) } else { expandedLocations.remove(provider) } }))
                if expandedLocations.contains(provider) {
                    if provider == .codex { codexLocations } else { claudeLocations }
                }
            }
        }
    }

    private func locationSummary(_ provider: AgentProvider) -> String {
        if provider == .codex {
            return executable.isEmpty && home.isEmpty ? L10n.text("settings.auto_discovery") : L10n.text("main.location.custom")
        }
        return claudeHome.isEmpty ? (resolvedClaudeHome as NSString).abbreviatingWithTildeInPath : L10n.text("main.location.custom")
    }

    private var codexCLIRow: some View {
        let report = cliReport
        let (tint, state): (Color, String) = report == nil ? (.secondary, L10n.text("provider.state.searching")) :
            report?.selected != nil ? (MainPalette.positive, L10n.text("provider.state.found")) : (MainPalette.attention, L10n.text("provider.state.not_found"))
        return CardStatusRow(title: "Codex CLI", state: state, tint: tint, help: report?.selected?.url.path,
                             detail: report?.selected == nil ? report?.issue : nil) {
            if report != nil, report?.selected == nil {
                Button(L10n.text("settings.rescan")) { cliScanRevision += 1 }.buttonStyle(.main)
            }
        }
    }

    private var claudeMonitoringRow: some View {
        let (tint, state): (Color, String) = switch model.claudeLocalSetup {
        case .ready: (MainPalette.positive, L10n.text("provider.state.ready"))
        case .checking, .configuring: (.secondary, L10n.text("provider.state.configuring"))
        case .missingHome: (.secondary, L10n.text("provider.state.no_home"))
        case .failed: (MainPalette.attention, L10n.text("provider.state.failed"))
        }
        return CardStatusRow(title: L10n.text("provider.monitoring"), state: state, tint: tint,
                             help: model.claudeLocalSetup == .failed ? L10n.text("claude.monitoring_setup_failed") : nil) {
            if model.claudeLocalSetup == .failed {
                Button(L10n.text("connections.retry")) { model.retryClaudeLocalSetup() }.buttonStyle(.main)
            }
        }
    }

    /// Sign-in reads as a status. A button appears only when Claude needs the
    /// user; switching accounts otherwise waits in the row's menu.
    private var claudeAccountRow: some View {
        let workspace = model.claudeNeedsOrganizationSelection, signedOut = model.claudeConnectionNeeded && !workspace
        let signedIn = !model.claudeConnectionNeeded && model.claudeQuotaSource != nil
        let (tint, key): (Color, String) =
            workspace ? (MainPalette.attention, "claude.account.workspace_needed") :
            signedOut ? (MainPalette.attention, "claude.account.signed_out") :
            signedIn ? (MainPalette.positive, "claude.account.signed_in") :
            model.providerRefreshing(.claude) ? (.secondary, "claude.account.checking") : (.secondary, "claude.account.unavailable")
        let unavailable = model.providerRefreshing(.claude) || resolvedClaudeHome != model.claudeHome.path || !model.isModuleEnabled(.claude)
        return CardStatusRow(title: L10n.text("claude.account"), state: L10n.text(key), tint: tint,
                             help: signedIn ? model.claudeQuotaSource?.label : nil) {
            Group {
                if workspace {
                    Button(L10n.text("claude.quota.choose_workspace")) { model.chooseClaudeOrganization() }
                        .buttonStyle(.main).help(L10n.text("claude.quota.choose_workspace_help"))
                } else if signedOut {
                    Button(L10n.text("claude.quota.connect")) { model.signInClaudeQuota() }
                        .buttonStyle(.mainProminent).help(L10n.text("claude.quota.connect_help"))
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
        CardPathField(title: L10n.text("settings.cli_path"), text: $executable, prompt: L10n.text("settings.auto_discovery"),
            issue: textIssues[.cli], focus: $focusedText, field: .cli, commit: { commit(.cli) }, choose: { choose(directory: false) },
            extra: cliReport.flatMap { report in
                report.candidates.count > 1 ? AnyView(Menu(L10n.text("settings.other_locations")) {
                    ForEach(report.candidates) { candidate in
                        Button(L10n.text("settings.cli_candidate", candidate.source, candidate.url.path)) {
                            executable = candidate.url.path; commit(.cli)
                        }
                    }
                }.fixedSize()) : nil
            })
        CardPathField(title: L10n.text("settings.codex_home"), text: $home, prompt: L10n.text("settings.home_placeholder"),
            issue: textIssues[.codexHome], focus: $focusedText, field: .codexHome, commit: { commit(.codexHome) },
            choose: { choose(directory: true) })
    }

    @ViewBuilder private var claudeLocations: some View {
        CardPathField(title: L10n.text("provider.claude_home"), text: $claudeHome, prompt: "~/.claude",
            issue: textIssues[.claudeHome], focus: $focusedText, field: .claudeHome, commit: { commit(.claudeHome) },
            choose: chooseClaudeHome)
    }

    /// One card per component category. Options that only matter while a
    /// component is shown sit in its row, under its title.
    private func warning(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MainPalette.attention).fixedSize(horizontal: false, vertical: true)
    }

    private func moduleMode(_ provider: AgentProvider) -> ProviderModuleMode { modules.mode(for: provider) }
    private func moduleEnabled(_ provider: AgentProvider) -> Bool {
        switch moduleMode(provider) {
        case .automatic: return model.providerDetected(provider)
        case .enabled: return true
        case .disabled: return false
        }
    }
    private func moduleBinding(_ provider: AgentProvider) -> Binding<Bool> {
        Binding(get: { moduleEnabled(provider) }, set: { modules.setMode($0 ? .enabled : .disabled, for: provider) })
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
        if panel.runModal() == .OK, let path = panel.url?.path { claudeHome = path; commit(.claudeHome) }
    }
    private func chooseDeepSeekHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = L10n.text("deepseek.choose_home")
        if panel.runModal() == .OK, let path = panel.url?.path { deepseekHome = path; commit(.deepseekHome) }
    }
    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = directory ? L10n.text("settings.choose_home") : L10n.text("settings.choose_cli")
        if panel.runModal() == .OK, let path = panel.url?.path {
            if directory { home = path; commit(.codexHome) } else { executable = path; commit(.cli) }
        }
    }
    /// Every non-text setting; any change is written and applied shortly
    /// after, so a slider drag or quick toggling restarts sources at most once.
    private var liveSettings: LiveSettings {
        LiveSettings(modules: modules, displayMode: displayMode, position: position, layout: compactLayout, componentOptions: componentOptions,
            barSize: barSize, appearance: appearance, theme: theme, accent: accent,
            quotaStyle: quotaStyle, deepseekPanelStyle: deepseekPanelStyle, fullscreen: fullscreen, displayID: displayID, positionPerDisplay: positionPerDisplay, metric: metric, singleTask: singleTask,
            windowID: windowID, claudeWindowID: claudeWindowID, retention: completedRetention, hideProjects: hideProjects, showsAppButtons: showsAppButtons,
            monitorSSH: monitorSSH, monitorRemoteControl: monitorRemoteControl, showEmbeddedClaudeSessions: showEmbeddedClaudeSessions,
            showEmbeddedCodexSessions: showEmbeddedCodexSessions, showClaudeCloudProjects: showClaudeCloudProjects, claudeProgressRing: claudeProgressRing, deepseekSource: deepseekSource, deepseekLowBalance: deepseekLowBalance,
            codexProgressRing: codexProgressRing, deepseekProgressRing: deepseekProgressRing,
            showsDeepSeekTurnCost: showsDeepSeekTurnCost, deepseekSpeedSource: deepseekSpeedSource, deepseekSpikeLimit: deepseekSpikeLimit, deepseekBudgets: deepseekBudgets,
            quotaRings: quotaRings)
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            applyNow()
        }
    }

    private func applyNow() {
        applyTask?.cancel(); applyTask = nil
        let defaults = UserDefaults.standard
        defaults.set(monitorSSH, forKey: "monitorSSH")
        defaults.set(monitorRemoteControl, forKey: "monitorRemoteControl")
        modules.save(to: defaults)
        displayMode.save(to: defaults)
        position?.save(to: defaults)
        compactLayout.save(to: defaults)
        componentOptions.save(to: defaults)
        barSize.save(to: defaults)
        // Retired preferences.
        for key in ["performanceRefreshMode", "quotaDashboardPeriod", "showInMenuBar",
                    "glassStyle", "glassTint", "glassTransparency", "glassCornerRadius",
                    "islandWidthMode", "specifiedIslandWidth", "collapsedIslandWidth", "expandedIslandWidth",
                    "lowQuotaReminder", "inputReminder", "completionReminder", "claudeSSHHosts"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(appearance.rawValue, forKey: "islandAppearance")
        defaults.set(theme.rawValue, forKey: AppTheme.defaultsKey)
        defaults.set(accent.rawValue, forKey: PacerAccent.defaultsKey)
        quotaStyle.save(to: defaults)
        deepseekPanelStyle.save(to: defaults)
        defaults.set(fullscreen, forKey: "showInFullscreen")
        DisplayIdentity.choose(displayID, in: defaults)
        defaults.set(positionPerDisplay, forKey: IslandScreenMemory.enabledKey)
        defaults.set(metric, forKey: "compactMetric")
        defaults.set(singleTask.rawValue, forKey: ActivityBadgeSingleTask.defaultsKey)
        defaults.set(windowID, forKey: "quotaWindowID")
        defaults.set(claudeWindowID, forKey: "claudeQuotaWindowID")
        defaults.set(completedRetention, forKey: "completedRetentionMinutes")
        defaults.set(hideProjects, forKey: "hideProjects")
        defaults.set(deepseekSource.rawValue, forKey: DeepSeekBalanceSource.defaultsKey)
        for (key, value) in [(IslandModel.deepseekLowBalanceKey, deepseekLowBalance), (IslandModel.deepseekSpikeLimitKey, deepseekSpikeLimit)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: IslandModel.legacyDeepSeekLowBalanceKey)
        deepseekBudgets.save(to: defaults)
        for slot in QuotaRingSlot.allCases {
            let value = quotaRings[slot.rawValue]
            if value.isEmpty { defaults.removeObject(forKey: slot.defaultsKey) } else { defaults.set(value, forKey: slot.defaultsKey) }
        }
        model.applySettings(sourceChanged: false)
    }

    /// Validates one text setting; a valid change is written and applied at once.
    private func commit(_ field: TextSetting) {
        let defaults = UserDefaults.standard
        func directoryExists(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        switch field {
        case .cli:
            let cli = CodexExecutableResolver.normalize(executable)
            guard cli != (defaults.string(forKey: "codexExecutable") ?? "") else { textIssues[field] = nil; return }
            if !cli.isEmpty, let issue = CodexExecutableResolver.discover(customPath: cli).issue { textIssues[field] = issue; return }
            defaults.set(cli, forKey: "codexExecutable")
        case .codexHome:
            let directory = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard directory != (defaults.string(forKey: "codexHome") ?? "") else { textIssues[field] = nil; return }
            guard directory.isEmpty || directoryExists((directory as NSString).expandingTildeInPath) else {
                textIssues[field] = L10n.text("settings.invalid_home"); return
            }
            defaults.set(directory, forKey: "codexHome")
        case .claudeHome:
            let directory = claudeHome.trimmingCharacters(in: .whitespacesAndNewlines)
            guard directory != (defaults.string(forKey: "claudeHome") ?? "") else { textIssues[field] = nil; return }
            guard directory.isEmpty || directoryExists(resolvedClaudeHome) else {
                textIssues[field] = L10n.text("provider.invalid_claude_home"); return
            }
            defaults.set(directory, forKey: "claudeHome")
        case .deepseekHome:
            let directory = deepseekHome.trimmingCharacters(in: .whitespacesAndNewlines)
            guard directory != (defaults.string(forKey: "deepseekHome") ?? "") else { textIssues[field] = nil; return }
            guard directory.isEmpty || directoryExists((directory as NSString).expandingTildeInPath) else {
                textIssues[field] = L10n.text("deepseek.invalid_home"); return
            }
            defaults.set(directory, forKey: "deepseekHome")
        }
        textIssues[field] = nil
        applyNow()
    }

    private func relaunchForLanguage() {
        guard !updater.sessionInProgress else { languageError = L10n.text("language.update_busy"); return }
        if let focusedText { commit(focusedText) }
        applyNow()
        language.save(to: .standard)
        if let relaunch = model.onRelaunch {
            if let reason = relaunch() { languageError = L10n.text("language.restart_failed", reason) }
        } else {
            languageError = L10n.text("language.restart_failed", L10n.text("language.missing_helper"))
        }
    }
}

enum TextSetting: Hashable { case cli, codexHome, claudeHome, deepseekHome }

private struct LiveSettings: Equatable {
    var modules: ProviderModules
    var displayMode: IslandDisplayMode
    var position: IslandPosition?
    var layout: CompactIslandLayout
    var componentOptions: CompactComponentOptions
    var barSize: CompactBarSize
    var appearance: IslandAppearance
    var theme: AppTheme
    var accent: PacerAccent
    var quotaStyle: ExpandedQuotaStyle
    var deepseekPanelStyle: DeepSeekPanelStyle
    var fullscreen: Bool
    var displayID: Int
    var positionPerDisplay: Bool
    var metric: String
    var singleTask: ActivityBadgeSingleTask
    var windowID: String
    var claudeWindowID: String
    var retention: Int
    var hideProjects: Bool
    var showsAppButtons: Bool
    var monitorSSH: Bool
    var monitorRemoteControl: Bool
    var showEmbeddedClaudeSessions: Bool
    var showEmbeddedCodexSessions: Bool
    var showClaudeCloudProjects: Bool
    var claudeProgressRing: Bool
    var deepseekSource: DeepSeekBalanceSource
    var deepseekLowBalance: Double?
    var codexProgressRing: Bool
    var deepseekProgressRing: Bool
    var showsDeepSeekTurnCost: Bool
    var deepseekSpeedSource: String
    var deepseekSpikeLimit: Double?
    var deepseekBudgets: DeepSeekBudgetSettings
    var quotaRings: [String]
}

/// System Settings style navigation tile.
struct SettingsIconTile: View {
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
