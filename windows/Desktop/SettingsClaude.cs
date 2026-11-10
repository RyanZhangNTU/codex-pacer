using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? claudeEnabled, claudeCloudProjects, claudeEmbedded, claudeProgress;
    private Button? claudeAutomatic, claudeSetupRetry;
    private TextBlock? claudeDetection, claudeLocalState, claudeSetupState;
    private StackPanel? claudeSections;
    private Border? claudeOff;
    private System.Windows.Shapes.Ellipse? claudeMonitorDot;

    private void ClearClaude()
    {
        ClearClaudeConnection();
        claudeEnabled = claudeCloudProjects = claudeEmbedded = claudeProgress = null; claudeAutomatic = null; claudeDetection = claudeLocalState = null; claudeSections = null;
        claudeSetupRetry = null; claudeSetupState = null; claudeOff = null; claudeMonitorDot = null;
    }
    /// As on the Mac: the header holds the module switch, then Status
    /// (monitoring, account, quota), Display, and folded custom locations.
    /// The quota trend lives on History.
    private void BuildClaude()
    {
        SetPaneHeader(ProviderHeader("claude", out var detection, out var module, out var automatic));
        claudeDetection = detection; claudeEnabled = module; claudeAutomatic = automatic;
        Identify(claudeEnabled, "settings.claude.enabled", "Claude"); editors.Add(claudeEnabled);
        BindToggle(claudeEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["claude"] = value ? "enabled" : "disabled" } });
        Identify(claudeAutomatic, "settings.claude.automatic", ui.Text("provider.restore_automatic")); editors.Add(claudeAutomatic);
        claudeAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["claude"] = "automatic" } });
        claudeOff = ModuleOffCard(); form.Children.Add(claudeOff);
        claudeSections = new StackPanel(); form.Children.Add(claudeSections);
        claudeSetupState = Detail(""); Identify(claudeSetupState, "settings.claude.setup", "");
        claudeSetupRetry = new Button { Content = ui.Text("connections.retry"), Visibility = Visibility.Collapsed };
        Identify(claudeSetupRetry, "settings.claude.retry_setup", ui.Text("windows.claude.retry_setup"));
        claudeSetupRetry.Click += async (sender, _) =>
        {
            if (sourceClosed || !ReferenceEquals(sender, claudeSetupRetry) || engine == null || !claudeSetupRetry.IsEnabled) return;
            try { await engine.SendAsync("retryClaudeSetup"); }
            catch (System.Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!sourceClosed && ReferenceEquals(sender, claudeSetupRetry)) claudeSetupState?.SetCurrentValue(TextBlock.TextProperty, ui.Text("windows.claude.setup_failed")); }
        };
        var monitoring = StatusRow(ui.Text("provider.monitoring"), out var dot, out var state, claudeSetupRetry, claudeSetupState);
        claudeMonitorDot = dot; claudeLocalState = state; Identify(claudeLocalState, "settings.claude.local_state", "");
        claudeSections.Children.Add(SectionTitle(ui.Text("main.section.status"), 0));
        claudeSections.Children.Add(Card(monitoring, BuildClaudeConnection(), ProviderQuotaRow("claude")));
        var cloud = Toggle("main.claude.cloud", "main.info.claude_cloud", "settings.claude.cloud_projects", out var cloudSwitch);
        claudeCloudProjects = cloudSwitch; editors.Add(cloudSwitch);
        RoutedEventHandler cloudChanged = async (_, _) =>
        {
            if (synchronizing || sourceClosed || providerConnectionClosed || activePane != "claude" || busy || claudeAccountBusy ||
                !ReferenceEquals(claudeCloudProjects, cloudSwitch) || !cloudSwitch.IsEnabled || !cloudSwitch.IsVisible) return;
            bool value = cloudSwitch.IsChecked == true;
            await Change(p => p with { ShowClaudeCloudProjects = value });
        };
        cloudSwitch.Checked += cloudChanged; cloudSwitch.Unchecked += cloudChanged;
        var embedded = Toggle("main.embedded", "main.info.claude_embedded", "settings.claude.embedded", out var embeddedSwitch);
        claudeEmbedded = embeddedSwitch; editors.Add(embeddedSwitch);
        BindToggle(embeddedSwitch, (p, value) => p with { ShowEmbeddedClaudeSessions = value });
        var progress = Toggle("main.claude.ring", "main.info.claude_ring", "settings.claude.progress_ring", out var progressSwitch);
        claudeProgress = progressSwitch; editors.Add(progressSwitch);
        BindToggle(progressSwitch, (p, value) => p with { ClaudeProgressRing = value });
        claudeSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
        claudeSections.Children.Add(Card(cloud, embedded, progress));
        claudeSections.Children.Add(Card(ProviderHomeEditor("claude")));
    }
    private void RefreshClaude()
    {
        if (claudeEnabled == null || engine == null) return;
        var snapshot = engine.LatestSnapshot;
        var module = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "claude");
        string mode = session.Current.ProviderModes["claude"];
        bool enabled = module?.Enabled == true, connected = !providerConnectionClosed && !engine.IsConnectionClosed;
        claudeEnabled.IsChecked = enabled;
        claudeEnabled.IsEnabled = !busy && !session.RequiresRestart && connected && snapshot != null;
        claudeDetection!.Text = ui.Text(module?.Installed == true ? "windows.provider.detected" : module?.Installed == false ? "windows.provider.not_detected" : "provider.state.searching")
            + (mode == "automatic" ? " · " + ui.Text("provider.automatic") : "");
        claudeAutomatic!.Visibility = mode == "automatic" ? Visibility.Collapsed : Visibility.Visible;
        claudeAutomatic.IsEnabled = claudeEnabled.IsEnabled;
        claudeSections!.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (claudeOff != null) claudeOff.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        claudeCloudProjects!.IsChecked = session.Current.ShowClaudeCloudProjects;
        claudeEmbedded!.IsChecked = session.Current.ShowEmbeddedClaudeSessions;
        claudeEmbedded.IsEnabled = enabled && connected && !busy && !session.RequiresRestart;
        claudeProgress!.IsChecked = session.Current.ClaudeProgressRing;
        claudeProgress.IsEnabled = claudeEmbedded.IsEnabled;
        claudeCloudProjects.IsEnabled = enabled && connected && !busy && !claudeAccountBusy && !session.RequiresRestart;
        string setup = !connected ? "failed" : snapshot?.ClaudeSetup?.State ?? (snapshot?.Demo == true ? "ready" : "failed");
        bool logs = snapshot?.Sources.Any(value => (value.Id is "claude:local-logs" or "claude:demo") && value.Available) == true;
        // Monitoring reads as one state, as on the Mac; the setup sentence shows only when it says more.
        var (stateKey, tone) = setup switch
        {
            "failed" => ("provider.state.failed", "attention"),
            "settingUp" => ("provider.state.configuring", "neutral"),
            "missingHome" => ("provider.state.no_home", "neutral"),
            "ready" => ("provider.state.ready", "positive"),
            _ => (logs ? "provider.state.found" : "provider.state.no_home", "neutral")
        };
        SetStatus(claudeMonitorDot, claudeLocalState, ui.Text(stateKey), tone);
        claudeSetupState!.Text = ClaudeSetupDescription(ui, setup, snapshot?.ClaudeSetup);
        claudeSetupState.Visibility = setup == "ready" && snapshot?.ClaudeSetup is not { SpeedsEstimated: true } && snapshot?.ClaudeSetup?.LaunchMode != "powershell" ? Visibility.Collapsed : Visibility.Visible;
        claudeSetupState.SetResourceReference(TextBlock.ForegroundProperty, setup == "failed" ? "SettingsWarning" : "SettingsSecondary");
        claudeSetupRetry!.Visibility = setup == "failed" ? Visibility.Visible : Visibility.Collapsed;
        claudeSetupRetry.IsEnabled = enabled && connected && !busy && setup != "settingUp" && snapshot?.Demo == false;
        RefreshProviderQuotaRow("claude");
        RefreshClaudeConnection(connected && enabled);
    }
    internal static string ClaudeSetupDescription(UiText ui, string state, ClaudeHookSetup? setup)
    {
        string message = ui.Text("windows.claude.setup_" + (state switch
        { "ready" when setup?.SpeedsEstimated == true => setup.TelemetryConflictReason == "managed" ? "managed" : "conflict", "ready" => "ready", "settingUp" => "working", "missingHome" => "missing", "disabled" => "disabled", _ => "failed" }));
        return state == "ready" && setup?.LaunchMode == "powershell" ? message + " " + ui.Text("windows.claude.setup_slow") : message;
    }
}
