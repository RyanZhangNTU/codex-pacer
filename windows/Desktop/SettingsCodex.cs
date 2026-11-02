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
    private CheckBox? codexEnabled, codexEmbedded;
    private TextBlock? codexDetection, cliState, cliIssue, executableIssue, homeIssue, historyTitle;
    private QuotaHistoryView? codexHistory;
    private Ellipse? cliDot;
    private Button? codexAutomatic, cliRescan, cliCandidates;
    private StackPanel? codexSections;
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
        codexEnabled = codexEmbedded = null; codexDetection = cliState = cliIssue = executableIssue = homeIssue = historyTitle = null; codexHistory = null;
        cliDot = null; codexAutomatic = cliRescan = cliCandidates = null; codexSections = null;
        executableField = homeField = null; executablePreference = homePreference = null;
    }

    private void BuildCodex()
    {
        var tile = new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(9.88),
            Background = new SolidColorBrush(Color.FromRgb(102, 205, 187)), Margin = new Thickness(0, 0, 12, 0) };
        tile.Child = new IconGlyph { Symbol = "chevron.left.forwardslash.chevron.right", Width = 25, Height = 25,
            Ink = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)) };
        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(Label("Codex", 14, FontWeights.SemiBold)); codexDetection = Detail(""); name.Children.Add(codexDetection);
        var identity = new StackPanel { Orientation = Orientation.Horizontal }; identity.Children.Add(tile); identity.Children.Add(name);
        codexEnabled = new CheckBox { Style = (Style)FindResource("SettingsSwitch") };
        Identify(codexEnabled, "settings.codex.enabled", "Codex"); editors.Add(codexEnabled);
        BindToggle(codexEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = value ? "enabled" : "disabled" } });
        form.Children.Add(Card(Row(identity, codexEnabled, 62)));
        codexAutomatic = new Button { Content = ui.Text("provider.restore_automatic"), Style = (Style)FindResource("SettingsLink"),
            HorizontalAlignment = HorizontalAlignment.Right, FontSize = 11, Margin = new Thickness(0, 0, 10, 16) };
        Identify(codexAutomatic, "settings.codex.automatic", ui.Text("provider.restore_automatic")); editors.Add(codexAutomatic);
        codexAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = "automatic" } });
        form.Children.Add(codexAutomatic);
        codexSections = new StackPanel(); form.Children.Add(codexSections);
        codexSections.Children.Add(SectionHeader("windows.provider.local", 10));

        cliState = Detail(ui.Text("provider.state.searching")); cliState.Margin = new Thickness(0, 0, 8, 0);
        Identify(cliState, "settings.codex.cli.status", cliState.Text);
        cliDot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, 8, 0) };
        cliRescan = new Button { Content = ui.Text("settings.rescan"), Visibility = Visibility.Collapsed };
        Identify(cliRescan, "settings.codex.rescan", ui.Text("settings.rescan")); editors.Add(cliRescan);
        cliRescan.Click += async (_, _) => { sourceInspection = InspectSavedSourceAsync(); await sourceInspection; };
        var status = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        status.Children.Add(cliDot); status.Children.Add(cliState); status.Children.Add(cliRescan);
        var cli = new StackPanel(); cli.Children.Add(Row(Label("Codex CLI"), status, 36));
        cliIssue = Detail(""); cliIssue.Margin = new Thickness(10, 0, 10, 8); cli.Children.Add(cliIssue);
        var embedded = Toggle("codex.embedded_sessions", "codex.embedded_sessions_help", "settings.codex.embedded", out var embeddedSwitch);
        codexEmbedded = embeddedSwitch; editors.Add(embeddedSwitch);
        BindToggle(embeddedSwitch, (p, value) => p with { ShowEmbeddedCodexSessions = value });
        var locations = new Expander { Header = ui.Text("provider.custom_locations"), Style = (Style)FindResource("SettingsDisclosure"),
            IsExpanded = session.Current.CodexExecutable.Length > 0 || session.Current.CodexHome.Length > 0 };
        Identify(locations, "settings.codex.locations", ui.Text("provider.custom_locations"));
        var fields = new StackPanel { Margin = new Thickness(10, 6, 10, 10) };
        fields.Children.Add(SourceField(true, out executableField)); executableIssue = SourceIssue("settings.codex.executable.issue"); fields.Children.Add(executableIssue);
        fields.Children.Add(SourceField(false, out homeField)); homeIssue = SourceIssue("settings.codex.home.issue"); fields.Children.Add(homeIssue);
        locations.Content = fields; codexSections.Children.Add(Card(cli, embedded, locations));
        historyTitle = Label("", 13, FontWeights.SemiBold);
        historyTitle.Margin = new Thickness(10, 20, 0, 8); codexSections.Children.Add(historyTitle);
        codexHistory = new QuotaHistoryView(ui, PacerPalette.Codex, async () =>
        { await sourceReady; if (!sourceClosed && engine != null) await engine.SendAsync("retryQuota", new { provider = "codex" }); });
        codexSections.Children.Add(Card(codexHistory));
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
        var row = new Grid { MinHeight = 28, Margin = new Thickness(0, executable ? 0 : 10, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(field); Grid.SetColumn(actions, 1); row.Children.Add(actions); return row;
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
        codexDetection.Text = ui.Text(module?.Installed == false ? "windows.provider.not_detected" : module?.Installed == true ? "windows.provider.detected" : "provider.state.searching")
            + (mode == "automatic" ? " · " + ui.Text("provider.automatic") : "");
        codexAutomatic!.Visibility = mode == "automatic" ? Visibility.Collapsed : Visibility.Visible;
        codexSections.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
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
        _ = Dispatcher.InvokeAsync(() => { if (!sourceClosed) { synchronizing = true; try { RefreshCodex(); RefreshClaude(); RefreshDeepSeek(); RefreshProviderHome(); RefreshReminders(); RefreshCollapsed(); } finally { synchronizing = false; } } });
    }
    private void OnProviderStatus(string status)
    {
        if (Dispatcher.HasShutdownStarted || status is not ("engineStopped" or "engineProtocolFailed")) return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (sourceClosed) return;
            providerConnectionClosed = true; sourceInspectionRevision++; sourceReport = null; sourceInspectionFailed = true;
            synchronizing = true;
            try { UpdateSourceStatus(); RefreshCodex(); RefreshClaude(); RefreshDeepSeek(); RefreshProviderHome(); RefreshReminders(); }
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
