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
    @State private var configuringClaude = false
    @State private var removingClaude = false
    @State private var claudeSetupMessage: String?
    @State private var claudeSetupStatus: ClaudeHookInstaller.Status?
    @State private var claudeRemoteSetupMessages: [String: String] = [:]
    @State private var claudeRemoteSetupRequests: Set<String> = []
    @State private var showsResetExpiryDetails: Set<AgentProvider> = []
    @State private var displayMode = IslandDisplayMode.load()
    @State private var widthSettings = IslandWidthSettings.load()
    @State private var compactLayout = CompactIslandLayout.load()
    @State private var editingCompactLayout = false
    @State private var appearance = IslandAppearance.stored
    @State private var glass = IslandGlassSettings.stored
    @State private var fullscreen = UserDefaults.standard.bool(forKey: "showInFullscreen")
    @State private var showInMenuBar = UserDefaults.standard.bool(forKey: "showInMenuBar")
    @State private var displayID = UserDefaults.standard.integer(forKey: "displayID")
    @State private var metric = UserDefaults.standard.string(forKey: "compactMetric") ?? "remaining"
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
    @State private var testingCLI = false
    @State private var cliTestMessage: String?
    @State private var cliTestSucceeded = false
    private var languageChanges: Bool { language.resolved() != L10n.language }
    private var claudeSetupBusy: Bool { configuringClaude || removingClaude }
    private var claudeRemoteSetupBusy: Bool { !claudeRemoteSetupRequests.isEmpty || !model.configuringClaudeHosts.isEmpty }
    private var claudeSSHHostsChanged: Bool {
        claudeSSHHosts != (UserDefaults.standard.string(forKey: "claudeSSHHosts") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex Pacer").font(.system(size: 23, weight: .semibold))
            Form {
                Section(L10n.text("language.section")) {
                    Picker(L10n.text("language.label"), selection: $language) {
                        ForEach(LanguagePreference.allCases, id: \.rawValue) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    Text(L10n.text(languageChanges ? "language.restart_hint" : "language.hint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UpdateSettingsView(updater: updater, automaticallyChecks: $automaticUpdateChecks)
                moduleControls
                quotaHistorySections
                Section(L10n.text("settings.display")) {
                    Picker(L10n.text("settings.appearance"), selection: $appearance) {
                        Text(L10n.text("settings.classic")).tag(IslandAppearance.classic)
                        Text(L10n.text("settings.liquid_glass")).tag(IslandAppearance.liquidGlass)
                    }
                    .disabled(!IslandAppearance.supportsLiquidGlass)
                    .help(IslandAppearance.supportsLiquidGlass ? L10n.text("settings.applies_on_save") : L10n.text("settings.glass_requirement"))
                    Picker(L10n.text("settings.display_mode"), selection: $displayMode) {
                        Text(L10n.text("settings.automatic")).tag(IslandDisplayMode.automatic)
                        Text(L10n.text("settings.notch")).tag(IslandDisplayMode.notch)
                        Text(L10n.text("settings.floating")).tag(IslandDisplayMode.floating)
                    }
                    .help(L10n.text("settings.display_mode_help"))
                    Picker(L10n.text("settings.width_mode"), selection: $widthSettings.mode) {
                        Text(L10n.text("settings.width_adaptive")).tag(IslandWidthSettings.Mode.adaptive)
                        Text(L10n.text("settings.width_fixed")).tag(IslandWidthSettings.Mode.fixed)
                    }
                    IslandWidthControl(model: model, settings: $widthSettings, layout: compactLayout,
                        attached: displayMode == .notch || (displayMode == .automatic && model.isAttached))
                    Text(L10n.text(widthSettings.mode == .adaptive ? "settings.width_adaptive_help" : "settings.width_fixed_help"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("layout.customize")) { editingCompactLayout = true }
                    Text(L10n.text("layout.settings_hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L10n.text("settings.menu_bar"), isOn: $showInMenuBar)
                        .help(L10n.text("settings.menu_bar_help"))
                    Toggle(L10n.text("settings.fullscreen"), isOn: $fullscreen)
                    Picker(L10n.text("settings.display_picker"), selection: $displayID) {
                        Text(L10n.text("settings.main_display")).tag(0)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                            Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)
                        }
                    }
                    Picker(L10n.text("settings.compact_metric"), selection: $metric) {
                        Text(L10n.text("settings.remaining_quota")).tag("remaining")
                        Text(L10n.text("settings.pace_percentage")).tag("pace")
                    }
                    if moduleEnabled(.codex) { quotaWindowPicker(.codex, selection: $windowID) }
                    if moduleEnabled(.claude) { quotaWindowPicker(.claude, selection: $claudeWindowID) }
                }
                if appearance == .liquidGlass, IslandAppearance.supportsLiquidGlass {
                    Section(L10n.text("settings.liquid_glass")) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(red: 0.56, green: 0.84, blue: 0.79)).frame(width: 6, height: 6)
                            Text("Codex Pacer").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "gearshape").font(.system(size: 12))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 18).frame(height: 58)
                        .modifier(IslandSurface(appearance: .liquidGlass, attached: false, expanded: true, settings: glass))
                        .preferredColorScheme(.dark)
                        .accessibilityLabel(L10n.text("settings.glass_preview"))
                        Picker(L10n.text("settings.glass_style"), selection: $glass.style) {
                            ForEach(IslandGlassSettings.Style.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                        }
                        LabeledContent(L10n.text("settings.transparency")) {
                            HStack(spacing: 10) {
                                Slider(value: $glass.transparency, in: 0...1, step: 0.05)
                                    .accessibilityLabel(L10n.text("settings.transparency"))
                                Text("\(Int((glass.transparency * 100).rounded()))%")
                                    .monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                        Picker(L10n.text("settings.tint"), selection: $glass.tint) {
                            ForEach(IslandGlassSettings.Tint.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                        }
                        LabeledContent(L10n.text("settings.corner_radius")) {
                            HStack(spacing: 10) {
                                Slider(value: $glass.cornerRadius, in: 12...36, step: 1)
                                    .accessibilityLabel(L10n.text("settings.corner_radius"))
                                Text("\(Int(glass.cornerRadius))").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                        Button(L10n.text("common.restore_defaults")) { glass = IslandGlassSettings() }
                            .buttonStyle(.borderless)
                    }
                }
                Section(L10n.text("settings.reminders")) {
                    Toggle(L10n.text("settings.low_quota"), isOn: $lowReminder)
                    Toggle(L10n.text("settings.waiting_reminder"), isOn: $inputReminder)
                    Toggle(L10n.text("settings.completion_reminder"), isOn: $completionReminder)
                    Picker(L10n.text("settings.retention"), selection: $completedRetention) {
                        Text(L10n.text("settings.five_minutes")).tag(5)
                        Text(L10n.text("settings.fifteen_minutes")).tag(15)
                        Text(L10n.text("settings.thirty_minutes")).tag(30)
                        Text(L10n.text("settings.one_hour")).tag(60)
                        Text(L10n.text("settings.four_hours")).tag(240)
                        Text(L10n.text("settings.until_clicked")).tag(0)
                    }
                    Toggle(L10n.text("settings.system_notifications"), isOn: $systemNotifications)
                }
                Section(L10n.text("settings.privacy")) {
                    Toggle(L10n.text("settings.hide_projects"), isOn: $hideProjects)
                }
                if moduleEnabled(.codex) || moduleEnabled(.claude) {
                    Section(L10n.text("settings.data_source")) {
                        Toggle(L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
                    }
                }
                if moduleEnabled(.codex) {
                Section(L10n.text("provider.codex_source")) {
                    Toggle(L10n.text("settings.monitor_remote_control"), isOn: $monitorRemoteControl)
                    Text(L10n.text("settings.remote_control_help"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if monitorSSH, !model.unavailableSSH.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("settings.ssh_unavailable"))
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(Array(model.unavailableSSH.enumerated()), id: \.offset) { _, name in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(name).fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(L10n.text("source.ssh_unavailable"))
                                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize()
                                }
                                .font(.system(size: 12))
                            }
                            Text(L10n.text("source.ssh_retrying"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    HStack {
                        TextField(L10n.text("settings.cli_path"), text: $executable, prompt: Text(L10n.text("settings.auto_discovery")))
                        Button(L10n.text("common.choose")) { choose(directory: false) }
                    }
                    cliDiscovery
                    HStack {
                        TextField(L10n.text("settings.codex_home"), text: $home, prompt: Text(L10n.text("settings.home_placeholder")))
                        Button(L10n.text("common.choose")) { choose(directory: true) }
                    }
                }
                }
                claudeSourceControls
                Section(L10n.text("settings.subscriptions")) {
                    let statuses = model.enabledProviders.flatMap { Array(model.providerStreamStatuses($0).values) }
                    let connected = statuses.filter(\.connected).count
                    let attached = statuses.reduce(0) { $0 + $1.attachedThreads }
                    Text(L10n.text("settings.connections", connected, attached)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(saving || testingCLI || claudeSetupBusy)
            if let validation { Text(validation).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Button(L10n.text("common.quit")) { model.onQuit?() }
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("build.development")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.cancel"), action: onClose).keyboardShortcut(.cancelAction).disabled(saving || claudeSetupBusy || claudeRemoteSetupBusy)
                Button(L10n.text(saving ? "common.saving" : languageChanges ? "language.save_restart" : "common.save"), action: { save() })
                    .keyboardShortcut(.defaultAction).disabled(saving || claudeSetupBusy || claudeRemoteSetupBusy)
            }
        }
        .padding(24)
        .frame(width: 480, height: 670)
        .environment(\.locale, L10n.locale)
        .sheet(isPresented: $editingCompactLayout) {
            CompactLayoutEditor(model: model, layout: compactLayout,
                attached: displayMode == .notch || (displayMode == .automatic && model.isAttached),
                saving: saving || testingCLI || claudeSetupBusy || claudeRemoteSetupBusy, validation: validation) { value in save(layout: value) }
        }
        .onAppear {
            automaticUpdateChecks = updater.automaticallyChecks
            claudeSetupStatus = ClaudeHookInstaller.details(home: model.claudeHome)
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
            cliTestMessage = nil
            let path = executable
            let report = await Task.detached(priority: .utility) {
                CodexExecutableResolver.discover(customPath: path)
            }.value
            guard !Task.isCancelled else { return }
            cliReport = report
        }
        .onChange(of: home) { _, _ in cliTestMessage = nil }
        .onChange(of: model.settingsRevision) { _, _ in
            claudeSetupStatus = ClaudeHookInstaller.details(home: model.claudeHome)
        }
    }

    @ViewBuilder
    private var quotaHistorySections: some View {
        ForEach(model.enabledProviders) { provider in
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
                    Text(L10n.text(model.providerRefreshing(provider) ? "quota.loading" : "quota.not_connected"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let warning = model.providerHistoryWarning(provider) {
                    Label(L10n.text("quota.chart_warning"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).help(warning)
                }
                HStack(spacing: 12) {
                    if provider == .claude, model.claudeConnectionNeeded {
                        Button(L10n.text(model.claudeConnectionActionTitleKey)) { model.connectClaudeQuota() }
                            .help(L10n.text(model.claudeConnectionActionHelpKey))
                    }
                    Button(L10n.text(model.providerRefreshing(provider) ? "common.retrying" : "common.refresh")) {
                        model.retryQuotaConnection(for: provider)
                    }
                }.font(.system(size: 11)).disabled(model.providerRefreshing(provider))
            }
        }
    }

    private var moduleControls: some View {
        Section(L10n.text("provider.modules")) {
            ForEach([AgentProvider.codex, .claude], id: \.rawValue) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(isOn: moduleBinding(provider)) {
                        HStack(spacing: 8) {
                            Circle().fill(provider.tint).frame(width: 6, height: 6)
                            Text(provider.displayName)
                        }
                    }
                    Text(L10n.text(model.providerDetected(provider) ? "provider.detected" : "provider.not_detected") +
                        (moduleMode(provider) == .automatic ? " · " + L10n.text("provider.automatic") : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(L10n.text("provider.module_help")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.text("provider.restore_automatic")) {
                    modules.codexMode = .automatic; modules.claudeMode = .automatic
                }.font(.system(size: 11)).buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var claudeSourceControls: some View {
        if moduleEnabled(.claude) {
            let monitoringConfigured = claudeSetupStatus?.hooksConfigured ?? model.claudeMonitoringConfigured
            Section(L10n.text("provider.claude_source")) {
                HStack {
                    TextField(L10n.text("provider.claude_home"), text: $claudeHome,
                        prompt: Text("~/.claude"))
                    Button(L10n.text("common.choose")) { chooseClaudeHome() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("claude.quota.connect_help")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(L10n.text("claude.quota.connect")) { model.signInClaudeQuota() }
                            .help(L10n.text("claude.quota.connect_help"))
                        if model.claudeNeedsOrganizationSelection {
                            Button(L10n.text("claude.quota.choose_workspace")) { model.chooseClaudeOrganization() }
                                .help(L10n.text("claude.quota.choose_workspace_help"))
                        }
                    }
                    .font(.system(size: 11))
                    .disabled(model.providerRefreshing(.claude) || resolvedClaudeHome != model.claudeHome.path || !model.isModuleEnabled(.claude))
                }
                TextField(L10n.text("provider.claude_ssh_hosts"), text: $claudeSSHHosts,
                    prompt: Text(L10n.text("provider.claude_ssh_placeholder")))
                    .disabled(!monitorSSH)
                Text(L10n.text("provider.claude_ssh_help")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                claudeRemoteSetupControls
                if monitorSSH, !claudeSSHFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("settings.ssh_unavailable"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(claudeSSHFailures, id: \.self) { host in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(host).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(L10n.text("source.ssh_unavailable"))
                                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize()
                            }.font(.system(size: 12))
                        }
                        Text(L10n.text("source.ssh_retrying"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                HStack(spacing: 10) {
                    Image(systemName: monitoringConfigured ? "checkmark.circle" : "circle")
                        .foregroundStyle(monitoringConfigured ? Color.green : Color.secondary)
                    Text(L10n.text(monitoringConfigured ? "provider.monitoring_configured" : "provider.monitoring_needed"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L10n.text(configuringClaude ? "provider.configuring" : "provider.configure")) { configureClaude() }
                        .font(.system(size: 11))
                        .disabled(configuringClaude || resolvedClaudeHome != model.claudeHome.path)
                    if monitoringConfigured {
                        Button(L10n.text(removingClaude ? "provider.removing" : "provider.remove_monitoring")) { removeClaude() }
                            .font(.system(size: 11)).help(L10n.text("provider.remove_monitoring_help"))
                            .disabled(claudeSetupBusy || resolvedClaudeHome != model.claudeHome.path)
                    }
                }
                Text(L10n.text("provider.claude_monitoring_help")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if monitoringConfigured, let status = claudeSetupStatus {
                    Text(L10n.text(status.telemetryConflict ? "provider.telemetry_conflict" :
                        status.telemetryConfigured ? "provider.telemetry_configured" : "provider.telemetry_needed"))
                        .font(.system(size: 11)).foregroundStyle(status.telemetryConflict ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if resolvedClaudeHome != model.claudeHome.path || !model.isModuleEnabled(.claude) {
                    Text(L10n.text("settings.applies_on_save")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let claudeSetupMessage {
                    Text(claudeSetupMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var claudeRemoteSetupControls: some View {
        if !model.claudeRemoteTargets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("provider.remote_setup")).font(.system(size: 12, weight: .medium))
                ForEach(model.claudeRemoteTargets, id: \.id) { target in
                    claudeRemoteSetupRow(target)
                }
                if claudeSSHHostsChanged || monitorSSH != model.monitorsSSH || !model.isModuleEnabled(.claude) {
                    Text(L10n.text("settings.applies_on_save")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }
    }

    private func claudeRemoteSetupRow(_ target: RemoteActivityTarget) -> some View {
        let configuring = claudeRemoteSetupRequests.contains(target.id) || model.configuringClaudeHosts.contains(target.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(target.alias).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                    .textSelection(.enabled).help(target.alias)
                Spacer(minLength: 4)
                Button(L10n.text(configuring ? "provider.configuring" : "provider.configure")) {
                    configureClaudeRemote(target)
                }
                .font(.system(size: 11))
                .disabled(configuring || !monitorSSH || claudeSSHHostsChanged ||
                    monitorSSH != model.monitorsSSH || !model.isModuleEnabled(.claude))
                .accessibilityLabel(L10n.text("provider.remote_setup_action", target.alias))
            }
            if let status = model.claudeRemoteSetupStatus[target.id] {
                Text(L10n.text(status.hooksConfigured ? "provider.monitoring_configured" : "provider.monitoring_needed"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L10n.text(status.telemetryConflict ? "provider.telemetry_conflict" :
                    status.telemetryConfigured ? "provider.remote_metrics_configured" : "provider.telemetry_needed"))
                    .font(.system(size: 11)).foregroundStyle(status.telemetryConflict ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = claudeRemoteSetupMessages[target.id] {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func configureClaudeRemote(_ target: RemoteActivityTarget) {
        guard monitorSSH, monitorSSH == model.monitorsSSH, !claudeSSHHostsChanged, model.isModuleEnabled(.claude),
              !model.configuringClaudeHosts.contains(target.id), claudeRemoteSetupRequests.insert(target.id).inserted else { return }
        claudeRemoteSetupMessages.removeValue(forKey: target.id)
        Task { @MainActor in
            let failure = await model.configureClaudeRemote(targetID: target.id)
            if let failure { claudeRemoteSetupMessages[target.id] = failure }
            else if model.claudeRemoteSetupStatus[target.id] != nil {
                claudeRemoteSetupMessages[target.id] = L10n.text("provider.remote_setup_success") + " " + L10n.text("provider.remote_setup_restart")
            }
            claudeRemoteSetupRequests.remove(target.id)
        }
    }

    private var claudeSSHFailures: [String] {
        let prefix = "remote-ssh-discovered:"
        return model.providerStreamStatuses(.claude).filter { $0.key.hasPrefix(prefix) && !$0.value.connected }
            .map { String($0.key.dropFirst(prefix.count)) }.sorted()
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
    private func configureClaude() {
        guard !configuringClaude else { return }
        configuringClaude = true; claudeSetupMessage = nil
        Task { @MainActor in
            claudeSetupMessage = await model.configureClaudeMonitoring()
            claudeSetupStatus = ClaudeHookInstaller.details(home: model.claudeHome)
            configuringClaude = false
        }
    }
    private func removeClaude() {
        guard !claudeSetupBusy else { return }
        removingClaude = true; claudeSetupMessage = nil
        Task { @MainActor in
            claudeSetupMessage = await model.removeClaudeMonitoring()
            claudeSetupStatus = ClaudeHookInstaller.details(home: model.claudeHome)
            removingClaude = false
        }
    }

    @ViewBuilder private var cliDiscovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = cliReport {
                if let selected = report.selected {
                    Text(L10n.text("settings.detected_cli", selected.source))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(selected.url.path)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if let issue = report.issue {
                    Text(issue).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button(L10n.text("settings.rescan")) { cliScanRevision += 1 }
                    if !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(L10n.text("settings.use_automatic")) { executable = "" }
                    }
                    if report.candidates.count > 1 {
                        Menu(L10n.text("settings.other_locations")) {
                            ForEach(report.candidates) { candidate in
                                Button(L10n.text("settings.cli_candidate", candidate.source, candidate.url.path)) { executable = candidate.url.path }
                            }
                        }.fixedSize()
                    }
                    Button(testingCLI ? L10n.text("settings.testing") : L10n.text("settings.test_connection"), action: testCLIConnection)
                        .disabled(report.selected == nil)
                }.font(.system(size: 11))
            } else {
                Text(L10n.text("settings.finding_cli")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let cliTestMessage {
                Text(cliTestMessage)
                    .font(.system(size: 11)).foregroundStyle(cliTestSucceeded ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func testCLIConnection() {
        guard let candidate = cliReport?.selected, !testingCLI else { return }
        let requestedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawHome = requestedHome.isEmpty
            ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : requestedHome
        let resolvedHome = CodexExecutableResolver.normalize(rawHome)
        if !requestedHome.isEmpty {
            var isDirectory: ObjCBool = false
            guard resolvedHome.hasPrefix("/"), FileManager.default.fileExists(atPath: resolvedHome, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                cliTestSucceeded = false
                cliTestMessage = L10n.text("settings.home_missing", resolvedHome)
                return
            }
        }
        testingCLI = true
        cliTestMessage = L10n.text("settings.testing_detail")
        cliTestSucceeded = false
        Task { @MainActor in
            let client = CodexClient(executable: candidate.url, home: URL(fileURLWithPath: resolvedHome), timeout: 8)
            do {
                let snapshot = try await client.readQuota()
                cliTestSucceeded = !snapshot.windows.isEmpty
                cliTestMessage = snapshot.windows.isEmpty
                    ? L10n.text("settings.empty_quota")
                    : L10n.text("settings.connection_succeeded", snapshot.windows.count)
            } catch {
                cliTestSucceeded = false
                cliTestMessage = CodexDiagnosticText.description(of: error)
            }
            await client.disconnect()
            testingCLI = false
        }
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
    private func save(layout: CompactIslandLayout? = nil) {
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
        if let layout { compactLayout = layout.normalized }
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
            defaults.set(appearance.rawValue, forKey: "islandAppearance")
            glass.save()
            defaults.set(fullscreen, forKey: "showInFullscreen")
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            defaults.set(displayID, forKey: "displayID")
            defaults.set(metric, forKey: "compactMetric")
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
            } else { editingCompactLayout = false; onClose() }
        }
    }
}
