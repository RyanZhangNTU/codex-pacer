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
    private StackPanel? connectionSources, connectionHosts, connectionQuotas;
    private TextBlock? connectionTitle, connectionDetail, connectionQuotaHeader;
    private Border? connectionQuotaCard;
    private IconGlyph? connectionMark;
    private Ellipse? connectionHalo;
    private Button? connectionRetry;
    private string? connectionContent;
    private bool connectionBusy;
    private readonly List<Button> connectionActions = [];

    private void ClearConnections()
    {
        connectionsSSH = connectionsRemote = connectionsWSL = null;
        connectionSources = connectionHosts = connectionQuotas = null;
        connectionTitle = connectionDetail = connectionQuotaHeader = null; connectionQuotaCard = null; connectionMark = null; connectionHalo = null;
        connectionRetry = null; connectionContent = null;
        connectionActions.Clear();
    }
    private void BuildConnections()
    {
        // The summary leads with a tinted state mark, as on the Mac pane; Retry appears only while sources retry.
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; connectionTitle = Label("", 14, FontWeights.SemiBold); connectionDetail = Detail("");
        Identify(connectionTitle, "settings.connections.summary", ""); AutomationProperties.SetLiveSetting(connectionTitle, AutomationLiveSetting.Polite);
        text.Children.Add(connectionTitle); text.Children.Add(connectionDetail);
        connectionRetry = new Button { Content = ui.Text("connections.retry"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        Identify(connectionRetry, "settings.connections.retry", ui.Text("connections.retry")); editors.Add(connectionRetry);
        connectionRetry.Click += async (_, _) => await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("refreshTaskSources"); });
        connectionMark = new IconGlyph { Width = 15, Height = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        connectionHalo = new Ellipse { Opacity = 0.16 };
        var mark = new Grid { Width = 32, Height = 32, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        mark.Children.Add(connectionHalo); mark.Children.Add(connectionMark);
        var summary = new DockPanel { Margin = new Thickness(12, 10, 12, 10) };
        DockPanel.SetDock(mark, Dock.Left); DockPanel.SetDock(connectionRetry, Dock.Right);
        summary.Children.Add(mark); summary.Children.Add(connectionRetry); summary.Children.Add(text);
        form.Children.Add(Card(summary));
        form.Children.Add(SectionHeader("connections.section.tasks", 10));
        var remote = Toggle("settings.monitor_remote_control", "settings.remote_control_help", "settings.connections.remote_control", out var remoteSwitch);
        connectionsRemote = remoteSwitch; editors.Add(remoteSwitch);
        BindToggle(remoteSwitch, (p, value) => p with { MonitorRemoteControl = value });
        var wsl = Toggle("windows.connections.monitor_wsl", "windows.connections.wsl_help", "settings.connections.wsl", out var wslSwitch);
        connectionsWSL = wslSwitch; editors.Add(wslSwitch); BindToggle(wslSwitch, (p, value) => p with { MonitorWSL = value });
        // Source rows bring their own trailing hairline, so an empty list leaves no stray line above the switches.
        connectionSources = new StackPanel(); var tasks = new StackPanel(); tasks.Children.Add(connectionSources); tasks.Children.Add(remote);
        tasks.Children.Add(Hairline(10)); tasks.Children.Add(wsl); form.Children.Add(Card(tasks));
        form.Children.Add(SectionHeader("connections.section.ssh", 10));
        var ssh = Toggle("settings.monitor_ssh", null, "settings.connections.ssh", out var sshSwitch);
        connectionsSSH = sshSwitch; editors.Add(sshSwitch); BindToggle(sshSwitch, (p, value) => p with { MonitorSSH = value });
        connectionHosts = new StackPanel(); var hosts = new StackPanel(); hosts.Children.Add(ssh); hosts.Children.Add(connectionHosts); form.Children.Add(Card(hosts));
        connectionQuotaHeader = SectionHeader("layout.group.quota", 10); form.Children.Add(connectionQuotaHeader);
        connectionQuotas = new StackPanel(); connectionQuotaCard = Card(connectionQuotas); form.Children.Add(connectionQuotaCard);
    }
    private void RefreshConnections()
    {
        if (connectionTitle == null || connectionSources == null || connectionHosts == null || connectionQuotas == null) return;
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
        connectionTitle.Text = providerConnectionClosed ? ui.Text("windows.connection.closed") : page?.Title ?? ui.Text("connections.summary.checking");
        connectionDetail!.Text = page?.Detail ?? ""; connectionDetail.Visibility = connectionDetail.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        string summaryState = providerConnectionClosed ? "offline" : page?.State ?? "checking";
        connectionMark!.Symbol = summaryState switch
        { "connected" => "checkmark", "retrying" => "arrow.clockwise", "paused" => "pause", "offline" => "network.slash", "disabled" => "power", _ => "ellipsis" };
        connectionMark.SetResourceReference(IconGlyph.InkProperty, Tone(page?.Tone)); connectionHalo!.SetResourceReference(Shape.FillProperty, Tone(page?.Tone));
        AutomationProperties.SetName(connectionTitle, connectionTitle.Text + " " + connectionDetail.Text);
        connectionRetry!.Visibility = page?.Retry == true ? Visibility.Visible : Visibility.Collapsed;
        connectionRetry.IsEnabled = available && page?.State != "disabled";
        string content = JsonSerializer.Serialize(new { page, snapshot?.Sources, snapshot?.ClaudeRemoteSetups,
            readings = snapshot?.QuotaDashboard?.Providers.Select(value => new { value.Provider, value.Status, value.FiveHour.FreshnessText, value.FiveHour.SourceText }), available });
        if (content == connectionContent) return;
        connectionContent = content; connectionActions.Clear(); connectionSources.Children.Clear(); connectionHosts.Children.Clear(); connectionQuotas.Children.Clear();
        connectionQuotaHeader!.Visibility = connectionQuotaCard!.Visibility = Visibility.Collapsed;
        if (page == null) return;
        foreach (var source in page.Sources)
        {
            var module = source.Module; var details = new StackPanel();
            details.Children.Add(StatusLine((source.Kind == source.Name ? "" : source.Kind + " · ") + module.Label, module.Tone));
            QuotaLines(module, snapshot, details);
            var row = ConnectionRow(ProviderTile(module.Provider), source.Name, details, ModuleActions(module, snapshot, available, module.State == "connected" ? module.SessionsText : ""));
            Identify(row, "settings.connections.source." + source.Id, source.Name + " " + module.Label);
            connectionSources.Children.Add(row); connectionSources.Children.Add(Hairline(10));
        }
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
            var server = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(6) }; server.SetResourceReference(Border.BackgroundProperty, "SettingsButton");
            var glyph = new IconGlyph { Symbol = "server.rack", Width = 13, Height = 13 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); server.Child = glyph;
            var row = ConnectionRow(server, host.Name + " · " + host.Kind, details, actions);
            Identify(row, "settings.connections.host." + host.Id, host.Name + " " + host.Kind);
            connectionHosts.Children.Add(Hairline(10)); connectionHosts.Children.Add(row);
        }
        var readings = snapshot?.QuotaDashboard?.Providers ?? [];
        foreach (var reading in readings)
        {
            string detail = reading.Provider == "deepseek" ? snapshot?.DeepseekConnection?.Status?.Message ?? snapshot?.Wallet?.Dial?.Freshness ?? reading.FiveHour.FreshnessText :
                reading.Status?.Message ?? string.Join(" · ", new[] { reading.FiveHour.SourceText, reading.FiveHour.FreshnessText }.Where(value => !string.IsNullOrEmpty(value)));
            var state = Detail(detail); state.Margin = new Thickness(0, 2, 0, 0); if (reading.Status?.State == "error") state.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
            Button? retry = null;
            var quotaActions = reading.Provider == "deepseek" ? snapshot?.DeepseekConnection?.Status?.Actions : reading.Status?.Actions;
            if (quotaActions?.FirstOrDefault(value => value.Enabled) is { } quotaAction)
            {
                retry = ConnectionButton(quotaAction.Title, "settings.connections.quota." + reading.Provider, available);
                retry.Click += async (_, _) =>
                {
                    if (quotaAction.Kind == "settings") await NavigateAsync(reading.Provider);
                    else if (reading.Provider == "claude" && engine?.LatestSnapshot?.ClaudeConnection?.State is "signedOut" or "workspaceNeeded")
                        await NavigateAsync("claude");
                    else if (reading.Provider == "deepseek") await NavigateAsync("deepseek");
                    else await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("retryQuota", new { provider = reading.Provider }); });
                };
            }
            if (connectionQuotas.Children.Count > 0) connectionQuotas.Children.Add(Hairline(42));
            connectionQuotas.Children.Add(ConnectionRow(ProviderTile(reading.Provider), ProviderName(reading.Provider), state, retry));
        }
        connectionQuotaHeader.Visibility = connectionQuotaCard.Visibility = readings.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    /// A provider or host tile, the name over its state, and the row's trailing actions.
    private Grid ConnectionRow(Border tile, string name, UIElement details, UIElement? trailing)
    {
        var row = new Grid { Margin = new Thickness(10, 8, 10, 8), MinHeight = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tile.Margin = new Thickness(0, 0, 10, 0); tile.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(tile);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Label(name); title.TextTrimming = TextTrimming.CharacterEllipsis; title.ToolTip = name; text.Children.Add(title); text.Children.Add(details);
        Grid.SetColumn(text, 1); row.Children.Add(text);
        if (trailing is FrameworkElement end) { end.VerticalAlignment = VerticalAlignment.Center; end.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(end, 2); row.Children.Add(end); }
        return row;
    }
    private static Border ProviderTile(string provider) => GuideArt.Tile(GuideArt.ProviderSymbol(provider), GuideArt.ProviderTile(provider), 22, true);
    private Border Hairline(double inset)
    {
        var line = new Border { Height = 1, Margin = new Thickness(inset, 0, 10, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return line;
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
