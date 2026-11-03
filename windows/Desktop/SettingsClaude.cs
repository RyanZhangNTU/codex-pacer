using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? claudeEnabled, claudeCloudProjects, claudeEmbedded;
    private Button? claudeAutomatic, claudeSetupRetry;
    private TextBlock? claudeDetection, claudeLocalState, claudeSetupState;
    private StackPanel? claudeSections;

    private void ClearClaude()
    {
        ClearClaudeConnection();
        claudeEnabled = claudeCloudProjects = claudeEmbedded = null; claudeAutomatic = null; claudeDetection = claudeLocalState = null; claudeSections = null;
        claudeSetupRetry = null; claudeSetupState = null;
    }
    private void BuildClaude()
    {
        var tile = new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(9.88),
            Background = new SolidColorBrush(Color.FromRgb(255, 164, 119)), Margin = new Thickness(0, 0, 12, 0),
            Child = new IconGlyph { Symbol = "asterisk", Width = 25, Height = 25, Ink = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)) } };
        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(Label("Claude", 14, FontWeights.SemiBold)); claudeDetection = Detail(""); name.Children.Add(claudeDetection);
        var identity = new StackPanel { Orientation = Orientation.Horizontal }; identity.Children.Add(tile); identity.Children.Add(name);
        claudeEnabled = new CheckBox { Style = (Style)FindResource("SettingsSwitch") };
        Identify(claudeEnabled, "settings.claude.enabled", "Claude"); editors.Add(claudeEnabled);
        BindToggle(claudeEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["claude"] = value ? "enabled" : "disabled" } });
        form.Children.Add(Card(Row(identity, claudeEnabled, 62)));
        claudeAutomatic = new Button { Content = ui.Text("provider.restore_automatic"), Style = (Style)FindResource("SettingsLink"),
            HorizontalAlignment = HorizontalAlignment.Right, FontSize = 11, Margin = new Thickness(0, 0, 10, 16) };
        Identify(claudeAutomatic, "settings.claude.automatic", ui.Text("provider.restore_automatic")); editors.Add(claudeAutomatic);
        claudeAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["claude"] = "automatic" } });
        form.Children.Add(claudeAutomatic);
        claudeSections = new StackPanel(); form.Children.Add(claudeSections);
        claudeSections.Children.Add(SectionHeader("windows.provider.local", 10));
        claudeLocalState = Detail(""); Identify(claudeLocalState, "settings.claude.local_state", "");
        var help = Detail(ui.Text("windows.claude.local_help")); help.Margin = new Thickness(10, 0, 10, 10);
        claudeSetupState = Detail(""); Identify(claudeSetupState, "settings.claude.setup", "");
        claudeSetupRetry = new Button { Content = ui.Text("windows.claude.retry_setup"), Style = (Style)FindResource("SettingsLink") };
        Identify(claudeSetupRetry, "settings.claude.retry_setup", ui.Text("windows.claude.retry_setup"));
        claudeSetupRetry.Click += async (sender, _) =>
        {
            if (sourceClosed || !ReferenceEquals(sender, claudeSetupRetry) || engine == null || !claudeSetupRetry.IsEnabled) return;
            try { await engine.SendAsync("retryClaudeSetup"); }
            catch (System.Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!sourceClosed && ReferenceEquals(sender, claudeSetupRetry)) claudeSetupState?.SetCurrentValue(TextBlock.TextProperty, ui.Text("windows.claude.setup_failed")); }
        };
        var cloud = Toggle("claude.cloud_projects", "claude.cloud_projects_help", "settings.claude.cloud_projects", out var cloudSwitch);
        claudeCloudProjects = cloudSwitch; editors.Add(cloudSwitch);
        RoutedEventHandler cloudChanged = async (_, _) =>
        {
            if (synchronizing || sourceClosed || providerConnectionClosed || activePane != "claude" || busy || claudeAccountBusy ||
                !ReferenceEquals(claudeCloudProjects, cloudSwitch) || !cloudSwitch.IsEnabled || !cloudSwitch.IsVisible) return;
            bool value = cloudSwitch.IsChecked == true;
            await Change(p => p with { ShowClaudeCloudProjects = value });
        };
        cloudSwitch.Checked += cloudChanged; cloudSwitch.Unchecked += cloudChanged;
        var embedded = Toggle("claude.embedded_sessions", "claude.embedded_sessions_help", "settings.claude.embedded", out var embeddedSwitch);
        claudeEmbedded = embeddedSwitch; editors.Add(embeddedSwitch);
        BindToggle(embeddedSwitch, (p, value) => p with { ShowEmbeddedClaudeSessions = value });
        claudeSections.Children.Add(Card(Row(Label(ui.Text("windows.claude.local_logs")), claudeLocalState), help,
            Row(claudeSetupState, claudeSetupRetry),
            BuildClaudeConnection(), cloud, embedded, ProviderHomeEditor("claude")));
        BuildClaudeHistory(claudeSections);
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
        claudeCloudProjects!.IsChecked = session.Current.ShowClaudeCloudProjects;
        claudeEmbedded!.IsChecked = session.Current.ShowEmbeddedClaudeSessions;
        claudeEmbedded.IsEnabled = enabled && connected && !busy && !session.RequiresRestart;
        claudeCloudProjects.IsEnabled = enabled && connected && !busy && !claudeAccountBusy && !session.RequiresRestart;
        claudeLocalState!.Text = ui.Text(!connected ? "provider.state.failed" : snapshot?.Sources.Any(value =>
            (value.Id is "claude:local-logs" or "claude:demo") && value.Available) == true ? "provider.state.found" : "provider.state.no_home");
        string setup = !connected ? "failed" : snapshot?.ClaudeSetup?.State ?? (snapshot?.Demo == true ? "ready" : "failed");
        claudeSetupState!.Text = ClaudeSetupDescription(ui, setup, snapshot?.ClaudeSetup);
        claudeSetupRetry!.IsEnabled = enabled && connected && !busy && setup != "settingUp" && snapshot?.Demo == false;
        RefreshClaudeConnection(connected && enabled);
    }
    internal static string ClaudeSetupDescription(UiText ui, string state, ClaudeHookSetup? setup)
    {
        string message = ui.Text("windows.claude.setup_" + (state switch
        { "ready" when setup?.TelemetryConflict == true => "conflict", "ready" => "ready", "settingUp" => "working", "missingHome" => "missing", "disabled" => "disabled", _ => "failed" }));
        return state == "ready" && setup?.LaunchMode == "powershell" ? message + " " + ui.Text("windows.claude.setup_slow") : message;
    }
}
