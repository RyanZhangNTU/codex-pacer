using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? codexEnabled, codexEmbedded, codexProgress;
    private TextBlock? codexProgressState;
    private Button? codexProgressRetry;
    private FrameworkElement? codexProgressStatus;
    private TextBlock? codexDetection, cliState, cliIssue, executableIssue, homeIssue, historyTitle;
    private QuotaHistoryView? codexHistory;
    private Ellipse? cliDot;
    private Button? codexAutomatic, cliRescan, cliCandidates;
    private StackPanel? codexSections;
    private Border? codexOff;
    private Expander? codexLocations;
    private TextBox? executableField, homeField;
    private CodexSourceReport? sourceReport;
    private string? sourceInspectionKey, executablePreference, homePreference;
    private long sourceInspectionRevision;
    private bool sourceClosed, sourceInspectionFailed;
    private bool providerConnectionClosed;
    private long sourceCommitRevision;
    private readonly long[] sourceFieldRevision = [0, 0];
    private readonly string?[] pendingSourceValidation = [null, null];
    private Task sourceInspection = Task.CompletedTask;

    private void ClearCodex()
    {
        sourceInspectionRevision++; sourceCommitRevision++; Array.Clear(pendingSourceValidation); sourceInspectionKey = null; sourceReport = null;
        codexEnabled = codexEmbedded = codexProgress = null; codexDetection = cliState = cliIssue = executableIssue = homeIssue = historyTitle = null; codexHistory = null;
        codexProgressState = null; codexProgressRetry = null; codexProgressStatus = null;
        cliDot = null; codexAutomatic = cliRescan = cliCandidates = null; codexSections = null; codexOff = null; codexLocations = null;
        executableField = homeField = null; executablePreference = homePreference = null;
    }

    /// As on the Mac: the header holds the module switch, then Status (CLI and
    /// quota), Display, and folded custom locations. Remote Control lives on
    /// Remote and the quota trend on History.
    private void BuildCodex()
    {
        SetPaneHeader(ProviderHeader("codex", out var detection, out var module, out var automatic));
        codexDetection = detection; codexEnabled = module; codexAutomatic = automatic;
        Identify(codexEnabled, "settings.codex.enabled", "Codex"); editors.Add(codexEnabled);
        BindToggle(codexEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = value ? "enabled" : "disabled" } });
        Identify(codexAutomatic, "settings.codex.automatic", ui.Text("provider.restore_automatic")); editors.Add(codexAutomatic);
        codexAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = "automatic" } });
        codexOff = ModuleOffCard(); form.Children.Add(codexOff);
        codexSections = new StackPanel(); form.Children.Add(codexSections);

        cliRescan = new Button { Content = ui.Text("settings.rescan"), Visibility = Visibility.Collapsed };
        Identify(cliRescan, "settings.codex.rescan", ui.Text("settings.rescan")); editors.Add(cliRescan);
        cliRescan.Click += async (_, _) => { sourceInspection = InspectSavedSourceAsync(); await sourceInspection; };
        cliIssue = Detail(""); cliIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        var cli = StatusRow("Codex CLI", out var dot, out var state, cliRescan, cliIssue); cliDot = dot; cliState = state;
        cliState.Text = ui.Text("provider.state.searching"); Identify(cliState, "settings.codex.cli.status", cliState.Text);
        codexSections.Children.Add(SectionTitle(ui.Text("main.section.status"), 0));
        codexSections.Children.Add(Card(cli, ProviderQuotaRow("codex")));

        var embedded = Toggle("main.embedded", "main.info.codex_embedded", "settings.codex.embedded", out var embeddedSwitch);
        codexEmbedded = embeddedSwitch; editors.Add(embeddedSwitch);
        BindToggle(embeddedSwitch, (p, value) => p with { ShowEmbeddedCodexSessions = value });
        codexProgress = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
        Identify(codexProgress, "settings.codex.progress_ring", ui.Text("main.claude.ring")); editors.Add(codexProgress);
        BindToggle(codexProgress, (p, value) => p with { CodexProgressRing = value });
        codexProgressState = Detail(""); Identify(codexProgressState, "settings.codex.progress_state", "");
        codexProgressRetry = new Button { Content = ui.Text("connections.retry"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        Identify(codexProgressRetry, "settings.codex.progress_retry", ui.Text("connections.retry"));
        codexProgressRetry.Click += async (sender, _) =>
        {
            if (sourceClosed || !ReferenceEquals(sender, codexProgressRetry) || engine == null || !codexProgressRetry.IsEnabled) return;
            try { await engine.SendAsync("retryCodexProgressSetup"); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!sourceClosed && ReferenceEquals(sender, codexProgressRetry)) codexProgressState?.SetCurrentValue(TextBlock.TextProperty, ui.Text("codex.progress_setup.failed")); }
        };
        var progressEnd = new StackPanel { Orientation = Orientation.Horizontal }; progressEnd.Children.Add(codexProgressRetry); progressEnd.Children.Add(codexProgress);
        var progress = InfoRow(ui.Text("main.claude.ring"), progressEnd, ui.Text("codex.progress_ring_help"), codexProgressState, "settings.codex.progress_ring");
        codexProgressStatus = codexProgressState;
        codexSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
        codexSections.Children.Add(Card(embedded, progress));

        // Each location is a row of its own, as on the Mac: its name, the field, then Choose.
        var fields = new StackPanel { Margin = new Thickness(14, 0, 14, 0) };
        fields.Children.Add(Hairline(0, 0));
        fields.Children.Add(SourceField(true, out executableField)); executableIssue = SourceIssue("settings.codex.executable.issue"); fields.Children.Add(executableIssue);
        fields.Children.Add(Hairline(0, 0));
        fields.Children.Add(SourceField(false, out homeField)); homeIssue = SourceIssue("settings.codex.home.issue"); fields.Children.Add(homeIssue);
        codexLocations = Disclosure(ui.Text("provider.custom_locations"), fields,
            session.Current.CodexExecutable.Length > 0 || session.Current.CodexHome.Length > 0, "settings.codex.locations");
        codexSections.Children.Add(Card(codexLocations));
    }

    /// A custom location's row: a 96-wide name, the field, then its buttons, at least 44 tall.
    private Grid LocationRow(string title, TextBox field, UIElement actions)
    {
        var row = new Grid { MinHeight = 44 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = Label(title); name.VerticalAlignment = VerticalAlignment.Center; name.TextTrimming = TextTrimming.CharacterEllipsis; name.Margin = new Thickness(0, 0, 8, 0); row.Children.Add(name);
        field.VerticalAlignment = VerticalAlignment.Center; field.FontSize = 12.5; Grid.SetColumn(field, 1); row.Children.Add(field);
        if (actions is FrameworkElement end) end.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(actions, 2); row.Children.Add(actions); return row;
    }
    private TextBlock SourceIssue(string id)
    {
        var label = Detail(""); label.Visibility = Visibility.Collapsed; label.Margin = new Thickness(0, 3, 0, 6);
        label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); Identify(label, id, "");
        AutomationProperties.SetLiveSetting(label, AutomationLiveSetting.Polite); return label;
    }
    private Grid SourceField(bool executable, out TextBox field)
    {
        string key = executable ? "settings.cli_path" : "settings.codex_home";
        field = new TextBox { Style = (Style)FindResource("SettingsPathInput"), Tag = ui.Text(executable ? "settings.auto_discovery" : "settings.home_placeholder"),
            MinWidth = 0, MaxLength = 32768, VerticalContentAlignment = VerticalAlignment.Center };
        Identify(field, executable ? "settings.codex.executable" : "settings.codex.home", ui.Text(key));
        editors.Add(field);
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitSourceAsync(executable); } };
        field.LostKeyboardFocus += async (_, _) => { if (!synchronizing && !busy && !sourceClosed) await CommitSourceAsync(executable); };
        var choose = new Button { Content = ui.Text("common.choose"), Margin = new Thickness(8, 0, 0, 0) };
        Identify(choose, executable ? "settings.codex.choose_executable" : "settings.codex.choose_home", ui.Text(key) + ": " + ui.Text("common.choose"));
        choose.Click += async (_, _) =>
        {
            if (busy || sourceClosed) return;
            if (executable)
            {
                var dialog = new OpenFileDialog { Title = ui.Text(key), Filter = ui.Text("windows.settings.executable_filter"), CheckFileExists = true };
                if (dialog.ShowDialog(this) == true && executableField != null) { executableField.Text = dialog.FileName; await CommitSourceAsync(true); }
            }
            else
            {
                var dialog = new OpenFolderDialog { Title = ui.Text(key) };
                if (dialog.ShowDialog(this) == true && homeField != null) { homeField.Text = dialog.FolderName; await CommitSourceAsync(false); }
            }
        };
        editors.Add(choose);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        if (executable)
        {
            cliCandidates = new Button { Content = ui.Text("settings.other_locations"), Visibility = Visibility.Collapsed, Margin = new Thickness(8, 0, 0, 0) };
            Identify(cliCandidates, "settings.codex.other_locations", ui.Text("settings.other_locations")); editors.Add(cliCandidates);
            cliCandidates.Click += (_, _) => ShowOtherExecutables(); actions.Children.Add(cliCandidates);
        }
        actions.Children.Add(choose);
        return LocationRow(ui.Text(key), field, actions);
    }

    private void ShowOtherExecutables()
    {
        if (cliCandidates == null || sourceReport == null) return;
        var menu = new ContextMenu { PlacementTarget = cliCandidates, FontFamily = PacerFonts.Interface };
        foreach (var candidate in sourceReport.Candidates)
        {
            var choice = new MenuItem { Header = candidate.Label };
            choice.Click += async (_, _) => { if (executableField != null) { executableField.Text = candidate.Path; await CommitSourceAsync(true); } };
            menu.Items.Add(choice);
        }
        menu.IsOpen = true;
    }

    private void RefreshCodex()
    {
        if (codexEnabled == null || codexDetection == null || codexSections == null || engine == null) return;
        string mode = session.Current.ProviderModes["codex"];
        var module = engine.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == "codex");
        bool enabled = module?.Enabled ?? (mode != "disabled" && engine.LatestSnapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "codex") == true);
        codexEnabled.IsChecked = enabled;
        if (codexEmbedded != null) codexEmbedded.IsChecked = session.Current.ShowEmbeddedCodexSessions;
        if (codexProgress != null) codexProgress.IsChecked = session.Current.CodexProgressRing;
        if (codexProgressStatus != null && codexProgressState != null && codexProgressRetry != null)
        {
            var setup = engine.LatestSnapshot?.CodexProgressSetup;
            codexProgressStatus.Visibility = !demo && enabled && session.Current.CodexProgressRing && setup != null ? Visibility.Visible : Visibility.Collapsed;
            if (setup is "failed" or "missingCLI" or "conflict") codexProgressState.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
            else codexProgressState.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            codexProgressState.Text = setup == null ? "" : ui.Text("codex.progress_setup." + setup);
            codexProgressRetry.Visibility = setup is "failed" or "missingCLI" or "conflict" ? Visibility.Visible : Visibility.Collapsed;
            codexProgressRetry.IsEnabled = !busy && !session.RequiresRestart && !engine.IsConnectionClosed;
        }
        codexDetection.Text = ui.Text(module?.Installed == false ? "windows.provider.not_detected" : module?.Installed == true ? "windows.provider.detected" : "provider.state.searching")
            + (mode == "automatic" ? " · " + ui.Text("provider.automatic") : "");
        codexAutomatic!.Visibility = mode == "automatic" ? Visibility.Collapsed : Visibility.Visible;
        codexSections.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (codexOff != null) codexOff.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        if (codexLocations != null) codexLocations.Tag = ui.Text(session.Current.CodexExecutable.Length == 0 && session.Current.CodexHome.Length == 0 ? "settings.auto_discovery" : "main.location.custom");
        RefreshProviderQuotaRow("codex");
        if (executablePreference != session.Current.CodexExecutable)
        { executablePreference = session.Current.CodexExecutable; executableField!.Text = executablePreference; SetSourceIssue(executableIssue, null); }
        if (homePreference != session.Current.CodexHome)
        { homePreference = session.Current.CodexHome; homeField!.Text = homePreference; SetSourceIssue(homeIssue, null); }
        var history = engine.LatestSnapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == "codex")?.History;
        if (providerConnectionClosed || engine.IsConnectionClosed) codexHistory?.ShowUnavailable(ui.Text("windows.connection.closed"));
        else codexHistory?.Update(history);
        if (historyTitle != null) historyTitle.Text = sourceReport?.HistoryTitle ?? history?.Title ?? "";
        codexHistory?.SetInteractionEnabled(!busy && !session.RequiresRestart);
        string key = session.Current.CodexExecutable + "\0" + session.Current.CodexHome;
        if (sourceInspectionKey != key) sourceInspection = InspectSavedSourceAsync();
    }

    private void OnProviderSnapshot(EngineSnapshot snapshot)
    {
        if (Dispatcher.HasShutdownStarted) return;
        _ = Dispatcher.InvokeAsync(() => { if (!sourceClosed) { synchronizing = true; try { RefreshCodex(); RefreshClaude(); RefreshDeepSeek(); RefreshProviderHome(); RefreshReminders(); RefreshCollapsed(); RefreshConnections(); RefreshSidebar(); RefreshOverview(); RefreshHistory(); } finally { synchronizing = false; } } });
    }
    private void OnProviderStatus(string status)
    {
        if (Dispatcher.HasShutdownStarted || status is not ("engineStopped" or "engineProtocolFailed")) return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (sourceClosed) return;
            providerConnectionClosed = true; sourceInspectionRevision++; sourceReport = null; sourceInspectionFailed = true;
            synchronizing = true;
            try { UpdateSourceStatus(); RefreshCodex(); RefreshClaude(); RefreshDeepSeek(); RefreshProviderHome(); RefreshReminders(); RefreshConnections(); RefreshSidebar(); RefreshOverview(); RefreshHistory(); }
            finally { synchronizing = false; }
        });
    }

    private async Task InspectSavedSourceAsync()
    {
        if (engine == null || sourceClosed || activePane != "codex") return;
        long revision = ++sourceInspectionRevision;
        string executable = session.Current.CodexExecutable, home = session.Current.CodexHome;
        sourceInspectionKey = executable + "\0" + home; sourceReport = null; sourceInspectionFailed = false; UpdateSourceStatus();
        try
        {
            await sourceReady;
            if (sourceClosed || revision != sourceInspectionRevision) return;
            var report = await engine.QueryAsync<CodexSourceReport>("inspectCodexSource", new { codexExecutable = executable, codexHome = home });
            if (sourceClosed || revision != sourceInspectionRevision) return;
            sourceReport = report;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        {
            if (sourceClosed || revision != sourceInspectionRevision) return;
            sourceInspectionFailed = true;
        }
        UpdateSourceStatus();
    }

    internal async Task WaitForSourceInspectionAsync()
    { if (activePane == "codex") await sourceInspection; else if (activePane is "claude" or "deepseek") await homeInspection; }

    private void UpdateSourceStatus()
    {
        if (cliState == null || cliDot == null || cliIssue == null || cliRescan == null || cliCandidates == null) return;
        bool missing = sourceReport?.SelectedExecutable == null && (sourceReport != null || sourceInspectionFailed);
        string key = sourceInspectionFailed ? "provider.state.failed" : missing ? "provider.state.not_found" : sourceReport == null ? "provider.state.searching" : "provider.state.found";
        cliState.Text = ui.Text(key); AutomationProperties.SetName(cliState, cliState.Text);
        cliState.SetResourceReference(TextBlock.ForegroundProperty, missing ? "SettingsWarning" : "SettingsSecondary");
        cliDot.SetResourceReference(Shape.FillProperty, missing ? "SettingsWarning" : sourceReport == null ? "SettingsSecondary" : "SettingsSuccess");
        cliState.ToolTip = sourceReport?.SelectedExecutable;
        cliIssue.Text = sourceInspectionFailed ? ui.Text("windows.settings.inspect_failed") : sourceReport?.ExecutableIssue ?? "";
        cliIssue.Visibility = cliIssue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        cliRescan.Visibility = missing ? Visibility.Visible : Visibility.Collapsed;
        cliCandidates.Visibility = sourceReport?.Candidates.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (homeField != null) homeField.ToolTip = sourceReport?.EffectiveHome;
        if (historyTitle != null) historyTitle.Text = sourceReport?.HistoryTitle
            ?? engine?.LatestSnapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == "codex")?.History?.Title ?? "";
        if (providerConnectionClosed || engine?.IsConnectionClosed == true) codexHistory?.ShowUnavailable(ui.Text("windows.connection.closed"));
    }

    private static void SetSourceIssue(TextBlock? label, string? message)
    {
        if (label == null) return;
        label.Text = message ?? ""; label.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(label, label.Text);
    }

    private async Task CommitSourceAsync(bool executable)
    {
        if (busy || synchronizing || composing || sourceClosed || engine == null || executableField == null || homeField == null) return;
        string value = executable ? executableField.Text : homeField.Text;
        string saved = executable ? session.Current.CodexExecutable : session.Current.CodexHome;
        var problem = executable ? executableIssue : homeIssue;
        if (value == saved) { SetSourceIssue(problem, null); return; }
        if (Encoding.UTF8.GetByteCount(value) > 32768 || value.Any(char.IsControl))
        { SetSourceIssue(problem, ui.Text("windows.settings.invalid_path")); return; }
        int index = executable ? 0 : 1;
        if (pendingSourceValidation[index] == value) return;
        long paneRevision = sourceCommitRevision, revision = ++sourceFieldRevision[index];
        pendingSourceValidation[index] = value;
        var field = executable ? executableField : homeField;
        sourceInspectionRevision++; ClearIssue();
        try
        {
            await sourceReady;
            if (sourceClosed || paneRevision != sourceCommitRevision || revision != sourceFieldRevision[index] || field.Text != value) return;
            var report = await engine.QueryAsync<CodexSourceReport>("inspectCodexSource", new
            {
                codexExecutable = executable ? value : session.Current.CodexExecutable,
                codexHome = executable ? session.Current.CodexHome : value
            });
            if (sourceClosed || paneRevision != sourceCommitRevision || revision != sourceFieldRevision[index] || activePane != "codex" || field.Text != value) return;
            string? reason = executable ? report.ExecutableIssue : report.HomeIssue;
            SetSourceIssue(problem, reason);
            if (reason != null) return;
            var result = await Change(p => executable ? p with { CodexExecutable = report.Executable } : p with { CodexHome = report.Home });
            if (result != PreferencesApplyResult.Applied)
            { (executable ? executableField : homeField).Text = saved; return; }
            (executable ? executableField : homeField).Text = executable ? report.Executable : report.Home;
            if (report.Executable == session.Current.CodexExecutable && report.Home == session.Current.CodexHome)
            {
                sourceInspectionKey = session.Current.CodexExecutable + "\0" + session.Current.CodexHome;
                sourceReport = report; sourceInspectionFailed = false; UpdateSourceStatus();
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        { if (!sourceClosed && paneRevision == sourceCommitRevision && revision == sourceFieldRevision[index]) SetSourceIssue(problem, ui.Text("windows.settings.inspect_failed")); }
        finally { if (paneRevision == sourceCommitRevision && revision == sourceFieldRevision[index]) pendingSourceValidation[index] = null; }
    }
}
