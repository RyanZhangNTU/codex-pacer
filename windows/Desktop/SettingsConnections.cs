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
    private CheckBox? connectionsSSH, connectionsRemote, connectionsWSL;
    private StackPanel? connectionSources, connectionHosts, connectionControl, connectionWslHosts, connectionOthers, connectionRetryRow;
    private TextBlock? connectionTitle;
    private Button? connectionRetry;
    private string? connectionContent;
    private bool connectionBusy;
    private readonly List<Button> connectionActions = [];

    private void ClearConnections()
    {
        connectionsSSH = connectionsRemote = connectionsWSL = null;
        connectionSources = connectionHosts = connectionControl = connectionWslHosts = null;
        connectionTitle = null;
        connectionRetry = null; connectionContent = null; connectionOthers = null; connectionRetryRow = null;
        connectionActions.Clear();
    }
    /// As on the Mac: the overall state is the page's subtitle, then SSH hosts,
    /// Codex Remote Control and any other task source, each in its own card.
    /// WSL is the Windows-only fourth card. Quota lives on each service page.
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
        form.Children.Add(SectionTitle(ui.Text("connections.section.ssh"), 0)); form.Children.Add(Card(hosts));

        var remote = Toggle("settings.monitor_remote_control", "settings.remote_control_help", "settings.connections.remote_control", out var remoteSwitch);
        connectionsRemote = remoteSwitch; editors.Add(remoteSwitch);
        BindToggle(remoteSwitch, (p, value) => p with { MonitorRemoteControl = value });
        connectionControl = new StackPanel(); var control = new StackPanel(); control.Children.Add(remote); control.Children.Add(connectionControl);
        form.Children.Add(SectionTitle("Codex Remote Control")); form.Children.Add(Card(control));

        var wsl = Toggle("windows.connections.monitor_wsl", "windows.connections.wsl_help", "settings.connections.wsl", out var wslSwitch);
        connectionsWSL = wslSwitch; editors.Add(wslSwitch); BindToggle(wslSwitch, (p, value) => p with { MonitorWSL = value });
        connectionWslHosts = new StackPanel(); var wslCard = new StackPanel(); wslCard.Children.Add(wsl); wslCard.Children.Add(connectionWslHosts);
        form.Children.Add(SectionTitle("WSL")); form.Children.Add(Card(wslCard));

        connectionSources = new StackPanel();
        connectionRetry = new Button { Content = ui.Text("connections.retry"), VerticalAlignment = VerticalAlignment.Center };
        Identify(connectionRetry, "settings.connections.retry", ui.Text("main.remote.retry_all")); editors.Add(connectionRetry);
        connectionRetry.Click += async (_, _) => await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("refreshTaskSources"); });
        connectionRetryRow = new StackPanel(); connectionRetryRow.Children.Add(Hairline(14)); connectionRetryRow.Children.Add(InfoRow(ui.Text("main.remote.retry_all"), connectionRetry));
        var others = new StackPanel(); others.Children.Add(connectionSources); others.Children.Add(connectionRetryRow);
        connectionOthers = new StackPanel(); connectionOthers.Children.Add(SectionTitle(ui.Text("connections.section.tasks"))); connectionOthers.Children.Add(Card(others));
        form.Children.Add(connectionOthers);
    }
    private void RefreshConnections()
    {
        if (connectionTitle == null || connectionSources == null || connectionHosts == null || connectionControl == null || connectionWslHosts == null) return;
        var snapshot = engine?.LatestSnapshot; var page = snapshot?.Connections;
        bool available = !sourceClosed && !providerConnectionClosed && !busy && !connectionBusy && !session.RequiresRestart && engine != null;
        bool codex = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "codex")?.Enabled ?? snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "codex") == true;
        bool claude = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "claude")?.Enabled ?? snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "claude") == true;
        bool previous = synchronizing; synchronizing = true;
        try
        {
            connectionsRemote!.IsChecked = session.Current.MonitorRemoteControl; connectionsRemote.IsEnabled = available && codex;
            connectionsSSH!.IsChecked = session.Current.MonitorSSH; connectionsSSH.IsEnabled = available && (codex || claude);
            connectionsWSL!.IsChecked = session.Current.MonitorWSL; connectionsWSL.IsEnabled = available && (codex || claude);
        }
        finally { synchronizing = previous; }
        string summary = providerConnectionClosed ? ui.Text("windows.connection.closed") : page?.Title ?? ui.Text("connections.summary.checking");
        if (!providerConnectionClosed && page?.Detail is { Length: > 0 } detail) summary += " · " + detail;
        connectionTitle.Text = summary; AutomationProperties.SetName(connectionTitle, summary);
        connectionTitle.SetResourceReference(TextBlock.ForegroundProperty, page?.Tone == "warning" ? "SettingsWarning" : "SettingsSecondary");
        connectionRetryRow!.Visibility = page?.Retry == true ? Visibility.Visible : Visibility.Collapsed;
        connectionRetry!.IsEnabled = available && page?.State != "disabled";
        string content = JsonSerializer.Serialize(new { page, snapshot?.Sources, snapshot?.ClaudeRemoteSetups, available });
        if (content == connectionContent) return;
        connectionContent = content; connectionActions.Clear();
        connectionSources.Children.Clear(); connectionHosts.Children.Clear(); connectionControl.Children.Clear(); connectionWslHosts.Children.Clear();
        if (page == null) { connectionOthers!.Visibility = Visibility.Collapsed; return; }
        int others = 0;
        foreach (var source in page.Sources)
        {
            var module = source.Module; var details = new StackPanel();
            details.Children.Add(StatusLine((source.Kind == source.Name ? "" : source.Kind + " · ") + module.Label, module.Tone));
            QuotaLines(module, snapshot, details);
            var row = ConnectionRow(ProviderTile(module.Provider), source.Name, details, ModuleActions(module, snapshot, available, module.State == "connected" ? module.SessionsText : ""));
            Identify(row, "settings.connections.source." + source.Id, source.Name + " " + module.Label);
            // Remote Control sessions sit under their switch; SSH hosts are listed by host below.
            if (source.Key.StartsWith("remote-control:", StringComparison.Ordinal)) { connectionControl.Children.Add(Hairline(14)); connectionControl.Children.Add(row); }
            else if (!source.Key.StartsWith("remote-ssh-discovered:", StringComparison.Ordinal))
            { if (others++ > 0) connectionSources.Children.Add(Hairline(14)); connectionSources.Children.Add(row); }
        }
        connectionOthers!.Visibility = others > 0 || page.Retry ? Visibility.Visible : Visibility.Collapsed;
        foreach (var host in page.Hosts)
        {
            var details = new StackPanel(); var modules = new WrapPanel(); details.Children.Add(modules);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var module in host.Modules)
            {
                var line = StatusLine(ProviderName(module.Provider) + " " + module.Label + (module.SessionsText.Length > 0 ? " · " + module.SessionsText : ""), module.Tone);
                line.Margin = new Thickness(0, 0, 14, 0); modules.Children.Add(line);
                QuotaLines(module, snapshot, details); actions.Children.Add(ModuleActions(module, snapshot, available, ""));
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
    private static Border ProviderTile(string provider, double size = 22) => GuideArt.Tile(GuideArt.ProviderSymbol(provider), GuideArt.ProviderTile(provider), size, true);
    private Border Hairline(double inset)
    {
        var line = new Border { Height = 1, Margin = new Thickness(inset, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return line;
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
    private static string ProviderName(string provider) => provider switch { "codex" => "Codex", "claude" => "Claude", "deepseek" => "DeepSeek", _ => provider };
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
