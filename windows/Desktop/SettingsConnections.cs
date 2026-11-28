using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? connectionsSSH, connectionsWSL;
    private StackPanel? connectionHosts, connectionWslHosts;
    private TextBlock? connectionTitle;
    private Button? wslRefresh;
    private TextBlock? wslDetail;
    private bool wslInspectionRequested;
    private string? connectionContent;
    private bool connectionBusy;
    private readonly List<Button> connectionActions = [];

    private void ClearConnections()
    {
        connectionsSSH = connectionsWSL = null;
        connectionHosts = connectionWslHosts = null;
        connectionTitle = null; connectionContent = null;
        wslRefresh = null; wslDetail = null; wslInspectionRequested = false;
        connectionActions.Clear();
    }
    /// Other machines only, as on the Mac: the hosts' overall state is the page's
    /// subtitle, then SSH hosts and the Windows-only WSL card. Each module's own
    /// tasks on this computer, Codex's hooks and Dot tasks show on its page.
    private void BuildConnections()
    {
        var header = new StackPanel();
        var title = Label(PaneTitle("remote"), 22, FontWeights.Bold); AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1); header.Children.Add(title);
        connectionTitle = Label("", 12.5); connectionTitle.Margin = new Thickness(0, 3, 0, 0); connectionTitle.TextWrapping = TextWrapping.Wrap;
        connectionTitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Identify(connectionTitle, "settings.connections.summary", ""); AutomationProperties.SetLiveSetting(connectionTitle, AutomationLiveSetting.Polite);
        header.Children.Add(connectionTitle); SetPaneHeader(header);

        var ssh = Toggle("settings.monitor_ssh", null, "settings.connections.ssh", out var sshSwitch);
        connectionsSSH = sshSwitch; monitorSSH = sshSwitch; editors.Add(sshSwitch); BindToggle(sshSwitch, (p, value) => p with { MonitorSSH = value });
        connectionHosts = new StackPanel(); var hosts = new StackPanel(); hosts.Children.Add(ssh); hosts.Children.Add(connectionHosts);
        form.Children.Add(SectionTitle(ui.Text("connections.section.ssh"))); form.Children.Add(Card(hosts));

        var wsl = Toggle("windows.connections.monitor_wsl", "windows.connections.wsl_help", "settings.connections.wsl", out var wslSwitch);
        connectionsWSL = wslSwitch; editors.Add(wslSwitch); BindToggle(wslSwitch, (p, value) => p with { MonitorWSL = value });
        var energy = Label(ui.Text("windows.connections.wsl_energy"), 11.5);
        energy.Margin = new Thickness(14, 0, 14, 4); energy.TextWrapping = TextWrapping.Wrap;
        energy.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        wslRefresh = ConnectionRefreshButton("windows.connections.wsl_refresh", "settings.connections.refresh_wsl", "refreshWSL");
        wslDetail = Label("", 11.5); wslDetail.TextWrapping = TextWrapping.Wrap;
        connectionWslHosts = new StackPanel(); var wslCard = new StackPanel();
        wslCard.Children.Add(wsl); wslCard.Children.Add(energy);
        wslCard.Children.Add(InfoRow(ui.Text("windows.connections.wsl_distributions"), wslRefresh, detail: wslDetail));
        wslCard.Children.Add(connectionWslHosts);
        form.Children.Add(SectionTitle("WSL")); form.Children.Add(Card(wslCard));

    }
    /// Opens Codex's settings with the floating guide beside it on Settings' screen;
    /// a Codex that cannot open them takes the guide away again.
    private void OpenCodexHooksGuide(bool compactionOnly = false)
    {
        if ((demo && guideLinkLauncher == null) || sourceClosed || engine is not { IsConnectionClosed: false } client) return;
        var area = System.Windows.Forms.Screen.FromHandle(new System.Windows.Interop.WindowInteropHelper(this).Handle).WorkingArea;
        CodexHooksGuideFloat.Open(client, ui, Resources, area, compactionOnly);
        try
        {
            if (guideLinkLauncher != null)
            {
                if (!guideLinkLauncher(new Uri("codex://settings"))) CodexHooksGuideFloat.Current?.Close();
            }
            else { using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("codex://settings") { UseShellExecute = true }); }
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { CodexHooksGuideFloat.Current?.Close(); }
    }
    private Button ConnectionRefreshButton(string key, string id, string method)
    {
        string label = ui.Text(key);
        var button = new Button { Content = label, VerticalAlignment = VerticalAlignment.Center };
        Identify(button, id, label); editors.Add(button);
        button.Click += async (_, _) => await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync(method); });
        return button;
    }
    private void RefreshConnections()
    {
        if (connectionTitle == null || connectionHosts == null || connectionWslHosts == null) return;
        var snapshot = engine?.LatestSnapshot; var page = snapshot?.Connections;
        bool available = !sourceClosed && !providerConnectionClosed && !busy && !connectionBusy && !session.RequiresRestart && engine != null;
        bool codex = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "codex")?.Enabled ?? snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "codex") == true;
        bool claude = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "claude")?.Enabled ?? snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "claude") == true;
        bool previous = synchronizing; synchronizing = true;
        try
        {
            connectionsSSH!.IsChecked = session.Current.MonitorSSH; connectionsSSH.IsEnabled = available && (codex || claude);
            connectionsWSL!.IsChecked = session.Current.MonitorWSL && snapshot?.WslAvailability != "unavailable";
            connectionsWSL.IsEnabled = available && (codex || claude) &&
                (connectionsWSL.IsChecked == true || snapshot?.WslAvailability == "available");
        }
        finally { synchronizing = previous; }
        wslRefresh!.IsEnabled = available && snapshot != null && !snapshot.Demo && snapshot.WslAvailability != "checking";
        wslDetail!.Text = snapshot?.WslAvailability switch
        {
            "checking" => ui.Text("windows.connections.wsl_checking"),
            "unavailable" => ui.Text("windows.connections.wsl_unavailable"),
            "failed" => ui.Text("windows.connections.wsl_failed"),
            _ => ""
        };
        if (!wslInspectionRequested && available && snapshot != null && !snapshot.Demo && !session.Current.MonitorWSL)
        {
            wslInspectionRequested = true;
            _ = Dispatcher.InvokeAsync(() => RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("refreshWSL"); }));
        }
        string summary = providerConnectionClosed ? ui.Text("windows.connection.closed") : page?.Title ?? ui.Text("connections.summary.checking");
        if (!providerConnectionClosed && page?.Detail is { Length: > 0 } detail) summary += " · " + detail;
        // With no host monitoring on, there is nothing to sum up.
        if (!providerConnectionClosed && !session.Current.MonitorSSH && !session.Current.MonitorWSL) summary = "";
        connectionTitle.Text = summary; AutomationProperties.SetName(connectionTitle, summary);
        // The header line stays secondary, as the Mac's page subtitle; problems show on their rows.
        connectionTitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        string content = JsonSerializer.Serialize(new { page, snapshot?.Sources, snapshot?.ClaudeRemoteSetups, session.Current.MonitorSSH, session.Current.SshHostsOff, available });
        if (content == connectionContent) return;
        connectionContent = content; connectionActions.Clear();
        connectionHosts.Children.Clear(); connectionWslHosts.Children.Clear();
        if (page == null) return;
        foreach (var host in page.Hosts)
        {
            bool ssh = host.Kind == "SSH";
            if (ssh && !session.Current.MonitorSSH) continue;
            bool monitored = !ssh || !session.Current.SshHostsOff.Contains(host.Id, StringComparer.Ordinal);
            var details = new StackPanel();
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            if (!monitored) details.Children.Add(Detail(ui.Text("connections.host.not_monitored")));
            else
            {
                var modules = new WrapPanel(); details.Children.Add(modules);
                foreach (var module in host.Modules)
                {
                    var line = StatusLine(ProviderName(module.Provider) + " " + module.Label + (module.SessionsText.Length > 0 ? " · " + module.SessionsText : ""), module.Tone);
                    line.Margin = new Thickness(0, 0, 14, 0); modules.Children.Add(line);
                    QuotaLines(module, snapshot, details); actions.Children.Add(ModuleActions(module, snapshot, available, ""));
                }
            }
            // A host whose connection keeps failing has its own Retry, in place of the page-wide one.
            if (monitored && host.Modules.Any(module => module.State == "retrying" && !module.RetrySetup))
            {
                var retry = ConnectionButton(ui.Text("connections.retry"), "settings.connections.retry." + host.Id, available && page.State != "disabled");
                retry.Click += async (_, _) => await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("refreshTaskSources"); });
                actions.Children.Add(retry);
            }
            if (ssh)
            {
                var toggle = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), IsChecked = monitored,
                    IsEnabled = available, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
                Identify(toggle, "settings.connections.monitor." + host.Id,
                    ui.Text("connections.host.monitor").Replace("%@", host.Name, StringComparison.Ordinal));
                BindToggle(toggle, (p, value) => p.SetSSHHost(host.Id, value));
                actions.Children.Add(toggle);
            }
            var tiles = new StackPanel { Orientation = Orientation.Horizontal, Width = 42 };
            foreach (var module in host.Modules.DistinctBy(value => value.Provider))
            { var tile = ProviderTile(module.Provider, 18); tile.Margin = new Thickness(0, 0, 3, 0); tiles.Children.Add(tile); }
            var holder = new Border { Child = tiles };
            var row = ConnectionRow(holder, host.Name, details, actions);
            Identify(row, "settings.connections.host." + host.Id, host.Name + " " + host.Kind);
            var target = host.Kind.Contains("WSL", StringComparison.OrdinalIgnoreCase) ? connectionWslHosts : connectionHosts;
            target.Children.Add(Hairline(14)); target.Children.Add(row);
        }
    }
    /// A provider or host tile, the name over its state, and the row's trailing actions.
    private Grid ConnectionRow(Border tile, string name, UIElement details, UIElement? trailing)
    {
        var row = new Grid { Margin = new Thickness(14, 8, 14, 8), MinHeight = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tile.Margin = new Thickness(0, 0, 12, 0); tile.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(tile);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Label(name); title.TextTrimming = TextTrimming.CharacterEllipsis; title.ToolTip = name; text.Children.Add(title); text.Children.Add(details);
        Grid.SetColumn(text, 1); row.Children.Add(text);
        if (trailing is FrameworkElement end) { end.VerticalAlignment = VerticalAlignment.Center; end.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(end, 2); row.Children.Add(end); }
        return row;
    }
    private static Border ProviderTile(string provider, double size = 22) => ProviderIcon.Tile(provider, size);
    private Border Hairline(double inset, double end = 14)
    {
        var line = new Border { Height = 1, Margin = new Thickness(inset, 0, end, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return line;
    }
    /// A colored dot before the state, in warning color only when something needs attention.
    private StackPanel StatusLine(string text, string tone)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 0) };
        var dot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
        dot.SetResourceReference(Shape.FillProperty, Tone(tone)); line.Children.Add(dot);
        var label = Detail(text); label.Margin = new Thickness(0); if (tone == "warning") label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        line.Children.Add(label); return line;
    }
    private void QuotaLines(ConnectionModule module, EngineSnapshot? snapshot, Panel target)
    {
        if (!module.ReadsQuota) return;
        var quota = snapshot?.Sources.FirstOrDefault(source => source.Id == module.Id);
        if (quota?.QuotaWindows != null) foreach (var window in quota.QuotaWindows) target.Children.Add(Detail(window.Label + " · " + window.ValueText + (window.RemainingPercent != null ? "%" : "")));
        if (quota?.QuotaError is string error) { var warning = Detail(error); warning.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); target.Children.Add(warning); }
    }
    /// Session count and the module's own actions: retrying a failed remote setup or reading a remote quota.
    private StackPanel ModuleActions(ConnectionModule module, EngineSnapshot? snapshot, bool available, string sessions)
    {
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        if (sessions.Length > 0) { var count = Detail(sessions); count.Margin = new Thickness(0); count.VerticalAlignment = VerticalAlignment.Center; actions.Children.Add(count); }
        var setup = snapshot?.ClaudeRemoteSetups?.FirstOrDefault(row => row.SourceID == module.Key);
        if (module.RetrySetup && setup != null)
        {
            var retry = ConnectionButton(ui.Text("connections.retry"), "settings.connections.setup." + module.Key, available && setup.CanRetry && !setup.InFlight);
            if (setup.Message is string reason) retry.ToolTip = reason;
            retry.Click += async (_, _) => await RunConnectionAction(async () =>
            {
                var action = ConnectionActions.SetupRetry(engine?.LatestSnapshot, module, setup.Context);
                if (action != null && engine != null) await engine.SendAsync("retryClaudeRemoteSetup", action);
            });
            actions.Children.Add(retry);
        }
        if (module.ReadsQuota)
        {
            var quota = snapshot?.Sources.FirstOrDefault(source => source.Id == module.Id);
            var read = ConnectionButton(ui.Text("windows.connections.read_quota"), "settings.connections.read_quota." + module.Id, available && quota?.QuotaRefreshing != true);
            read.Click += async (_, _) => await RunConnectionAction(async () =>
            {
                var action = ConnectionActions.ReadQuota(engine?.LatestSnapshot, module);
                if (action != null && engine != null) await engine.SendAsync("readConnectionQuota", action);
            });
            actions.Children.Add(read);
        }
        return actions;
    }
    private Button ConnectionButton(string title, string id, bool enabled)
    {
        var button = new Button { Content = title, IsEnabled = enabled, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        Identify(button, id, title); connectionActions.Add(button); return button;
    }
    private string ProviderName(string provider) => engine?.LatestSnapshot?.Modules?.FirstOrDefault(module => module.Provider == provider)?.DisplayName
        ?? (provider switch { "codex" => "Codex", "claude" => "Claude", "deepseek" => "DeepSeek", _ => provider });
    private static string Tone(string? tone) => tone switch { "warning" => "SettingsWarning", "success" => "SettingsSuccess", _ => "SettingsSecondary" };
    private async Task RunConnectionAction(Func<Task> action)
    {
        if (sourceClosed || providerConnectionClosed || busy || connectionBusy || session.RequiresRestart || activePane != "remote") return;
        connectionBusy = true; RefreshConnections();
        try { await sourceReady; if (!sourceClosed && !providerConnectionClosed && activePane == "remote" && !session.RequiresRestart) await action(); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { if (!sourceClosed) ShowIssue("windows.connection.refresh_failed"); }
        finally { connectionBusy = false; if (!sourceClosed) RefreshConnections(); }
    }
}
