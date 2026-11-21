using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? claudeEnabled, claudeCloudProjects, claudeEmbedded, claudeProgress;
    private Button? claudeAutomatic;
    private TextBlock? claudeDetection, claudeCloudState;
    private StackPanel? claudeSections;
    private Border? claudeOff;

    private void ClearClaude()
    {
        ClearClaudeConnection();
        claudeEnabled = claudeCloudProjects = claudeEmbedded = claudeProgress = null; claudeAutomatic = null; claudeDetection = claudeCloudState = null; claudeSections = null;
        claudeOff = null;
    }
    /// As every module page: the header holds the module switch, then Status
    /// (task monitoring, account, usage), Display, and folded custom locations.
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
        claudeSections.Children.Add(SectionTitle(ui.Text("main.section.status"), 0));
        claudeSections.Children.Add(Card(ModuleStatusRow("claude.monitoring", ui.Text("provider.monitoring")), BuildClaudeConnection(), ProviderQuotaRow("claude")));
        var cloud = Toggle("main.claude.cloud", "main.info.claude_cloud", "settings.claude.cloud_projects", out var cloudSwitch);
        // While cloud projects are on but claude.ai is signed out, the row says so.
        claudeCloudState = Detail(""); claudeCloudState.Margin = new Thickness(14, -6, 14, 10); claudeCloudState.Visibility = Visibility.Collapsed;
        Identify(claudeCloudState, "settings.claude.cloud_state", "");
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
        var cloudRow = new StackPanel(); cloudRow.Children.Add(cloud); cloudRow.Children.Add(claudeCloudState);
        claudeSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
        claudeSections.Children.Add(Card(progress, embedded, cloudRow));
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
        // Monitoring reads as one state, as on every module page; the setup sentence shows only when it says more.
        RefreshModuleStatusRow("claude.monitoring", module?.Monitoring,
            ClaudeSetupVisible(setup, snapshot?.ClaudeSetup) ? ClaudeSetupDescription(ui, setup, snapshot?.ClaudeSetup) : "");
        // Cloud projects read claude.ai through the account above.
        bool signedOutCloud = session.Current.ShowClaudeCloudProjects && snapshot?.Demo != true && snapshot?.ClaudeConnection?.State == "signedOut";
        string cloudState = signedOutCloud ? ui.Text("connections.state.cloud_signed_out") : "";
        claudeCloudState!.Text = cloudState; System.Windows.Automation.AutomationProperties.SetName(claudeCloudState, cloudState);
        claudeCloudState.Visibility = cloudState.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        RefreshProviderQuotaRow("claude");
        RefreshClaudeConnection(connected && enabled);
    }
    internal static string ClaudeSetupDescription(UiText ui, string state, ClaudeHookSetup? setup)
    {
        // Estimated speeds use the Mac's note as is: the monitoring row above already says Ready.
        string message = state == "ready" && setup?.SpeedsEstimated == true
            ? ui.Text(setup.TelemetryConflictReason == "managed" ? "claude.telemetry.managed" : "claude.telemetry.kept_existing")
            : ui.Text("windows.claude.setup_" + (state switch
                { "ready" => "ready", "settingUp" => "working", "missingHome" => "missing", "disabled" => "disabled", _ => "failed" }));
        return state == "ready" && setup?.LaunchMode == "powershell" ? JoinSentences(message, ui.Text("windows.claude.setup_slow")) : message;
    }
    /// Chinese sentences follow a full-width full stop directly; other languages take a space.
    internal static string JoinSentences(string first, string second) => first.EndsWith('。') ? first + second : first + " " + second;
    /// A ready setup stays silent unless speeds are estimated or every hook starts through PowerShell.
    internal static bool ClaudeSetupVisible(string state, ClaudeHookSetup? setup) =>
        state != "ready" || setup is { SpeedsEstimated: true } || setup?.LaunchMode == "powershell";
}
