import AppKit
import SwiftUI
import PacerCore

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var updater: AppUpdater
    let onClose: () -> Void
    @State private var executable = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
    @State private var home = UserDefaults.standard.string(forKey: "codexHome") ?? ""
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
    @State private var lowReminder = UserDefaults.standard.bool(forKey: "lowQuotaReminder")
    @State private var inputReminder = UserDefaults.standard.bool(forKey: "inputReminder")
    @State private var completionReminder = UserDefaults.standard.bool(forKey: "completionReminder")
    @State private var completedRetention = UserDefaults.standard.object(forKey: "completedRetentionMinutes") as? Int ?? 30
    @State private var systemNotifications = UserDefaults.standard.bool(forKey: "systemNotifications")
    @State private var hideProjects = UserDefaults.standard.bool(forKey: "hideProjects")
    @State private var monitorSSH = UserDefaults.standard.object(forKey: "monitorSSH") == nil || UserDefaults.standard.bool(forKey: "monitorSSH")
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
                    Picker(L10n.text("settings.quota_window"), selection: $windowID) {
                        Text(L10n.text("settings.auto_weekly")).tag("auto")
                        if windowID != "auto", !(model.quota?.windows ?? []).contains(where: { $0.id == windowID }) {
                            Text(L10n.text("settings.saved_quota_window")).tag(windowID)
                        }
                        ForEach(model.quota?.buckets ?? []) { bucket in
                            ForEach(bucket.windows) { window in
                                Text(window.label + ((model.quota?.buckets.count ?? 0) > 1 ? " · " + (bucket.name ?? bucket.id) : "")).tag(window.id)
                            }
                        }
                    }
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
                Section(L10n.text("settings.data_source")) {
                    Toggle(L10n.text("settings.monitor_ssh"), isOn: $monitorSSH)
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
                Section(L10n.text("settings.subscriptions")) {
                    let connected = model.streamStatuses.values.filter(\.connected).count
                    let attached = model.streamStatuses.values.reduce(0) { $0 + $1.attachedThreads }
                    Text(L10n.text("settings.connections", connected, attached)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(saving || testingCLI)
            if let validation { Text(validation).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Button(L10n.text("common.quit")) { model.onQuit?() }
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("build.development")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.cancel"), action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
                Button(L10n.text(saving ? "common.saving" : languageChanges ? "language.save_restart" : "common.save"), action: save)
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24)
        .frame(width: 480, height: 670)
        .environment(\.locale, L10n.locale)
        .sheet(isPresented: $editingCompactLayout) {
            CompactLayoutEditor(model: model, layout: $compactLayout,
                attached: displayMode == .notch || (displayMode == .automatic && model.isAttached))
        }
        .onAppear {
            automaticUpdateChecks = updater.automaticallyChecks
            windowID = QuotaWindowSelection.validated(windowID, snapshot: model.quota)
        }
        .onChange(of: model.quota?.windows.map(\.id)) { _, _ in
            windowID = QuotaWindowSelection.validated(windowID, snapshot: model.quota)
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
    private func save() {
        if languageChanges && updater.sessionInProgress {
            validation = L10n.text("language.update_busy"); return
        }
        let shouldRelaunch = languageChanges
        let cli = CodexExecutableResolver.normalize(executable)
        let directory = home.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cli.isEmpty {
            if let issue = CodexExecutableResolver.discover(customPath: cli).issue {
                validation = issue; return
            }
        }
        if !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                validation = L10n.text("settings.invalid_home"); return
            }
        }
        widthSettings = widthSettings.normalized
        saving = true
        Task { @MainActor in
            let allowed = systemNotifications ? await NotificationDelivery.requestPermission() : false
            let requestedSystem = systemNotifications
            let defaults = UserDefaults.standard
            let sourceChanged = cli != (defaults.string(forKey: "codexExecutable") ?? "") || directory != (defaults.string(forKey: "codexHome") ?? "") || monitorSSH != model.monitorsSSH
            defaults.set(monitorSSH, forKey: "monitorSSH")
            defaults.set(cli, forKey: "codexExecutable")
            defaults.set(directory, forKey: "codexHome")
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
