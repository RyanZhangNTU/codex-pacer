using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CheckBox? connectionsSSH, connectionsRemote, connectionsWSL;
    private StackPanel? connectionSources, connectionHosts, connectionQuotas;
    private TextBlock? connectionTitle, connectionDetail;
    private Button? connectionRetry;
    private string? connectionContent;
    private bool connectionBusy;
    private readonly List<Button> connectionActions = [];

    private void ClearConnections()
    {
        connectionsSSH = connectionsRemote = connectionsWSL = null;
        connectionSources = connectionHosts = connectionQuotas = null;
        connectionTitle = connectionDetail = null; connectionRetry = null; connectionContent = null;
        connectionActions.Clear();
    }
    private void BuildConnections()
    {
        var text = new StackPanel(); connectionTitle = Label("", 13, FontWeights.SemiBold); connectionDetail = Detail("");
        Identify(connectionTitle, "settings.connections.summary", ""); AutomationProperties.SetLiveSetting(connectionTitle, AutomationLiveSetting.Polite);
        text.Children.Add(connectionTitle); text.Children.Add(connectionDetail);
        connectionRetry = new Button { Content = ui.Text("connections.retry") };
        Identify(connectionRetry, "settings.connections.retry", ui.Text("connections.retry")); editors.Add(connectionRetry);
        connectionRetry.Click += async (_, _) => await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("refreshTaskSources"); });
        form.Children.Add(Card(Row(text, connectionRetry, 58)));
        form.Children.Add(SectionHeader("connections.section.tasks", 10));
        var remote = Toggle("settings.monitor_remote_control", "settings.remote_control_help", "settings.connections.remote_control", out var remoteSwitch);
        connectionsRemote = remoteSwitch; editors.Add(remoteSwitch);
        BindToggle(remoteSwitch, (p, value) => p with { MonitorRemoteControl = value });
        var ssh = Toggle("settings.monitor_ssh", null, "settings.connections.ssh", out var sshSwitch);
        connectionsSSH = sshSwitch; editors.Add(sshSwitch); BindToggle(sshSwitch, (p, value) => p with { MonitorSSH = value });
        var wsl = Toggle("windows.connections.monitor_wsl", "windows.connections.wsl_help", "settings.connections.wsl", out var wslSwitch);
        connectionsWSL = wslSwitch; editors.Add(wslSwitch); BindToggle(wslSwitch, (p, value) => p with { MonitorWSL = value });
        form.Children.Add(Card(remote, ssh, wsl));
        connectionSources = new StackPanel(); connectionHosts = new StackPanel(); form.Children.Add(connectionSources); form.Children.Add(connectionHosts);
        form.Children.Add(SectionHeader("layout.group.quota", 10)); connectionQuotas = new StackPanel(); form.Children.Add(connectionQuotas);
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
        connectionTitle.SetResourceReference(TextBlock.ForegroundProperty, Tone(page?.Tone));
        connectionDetail!.Text = page?.Detail ?? "";
        AutomationProperties.SetName(connectionTitle, connectionTitle.Text + " " + connectionDetail.Text);
        connectionRetry!.IsEnabled = available && page?.State != "disabled";
        string content = JsonSerializer.Serialize(new { page, snapshot?.Sources, snapshot?.ClaudeRemoteSetups,
            readings = snapshot?.QuotaDashboard?.Providers.Select(value => new { value.Provider, value.Status, value.FiveHour.FreshnessText, value.FiveHour.SourceText }), available });
        if (content == connectionContent) return;
        connectionContent = content; connectionActions.Clear(); connectionSources.Children.Clear(); connectionHosts.Children.Clear(); connectionQuotas.Children.Clear();
        if (page == null) return;
        foreach (var source in page.Sources)
        {
            var identity = new StackPanel(); identity.Children.Add(Label(source.Name)); identity.Children.Add(Detail(source.Kind));
            var module = ConnectionModuleView(source.Module, snapshot, available);
            var row = Row(identity, module, 54); Identify(row, "settings.connections.source." + source.Id, source.Name + " " + source.Module.Label);
            connectionSources.Children.Add(Card(row));
        }
        foreach (var host in page.Hosts)
        {
            var grid = new Grid { Margin = new Thickness(10, 10, 10, 10) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            var identity = new StackPanel { Margin = new Thickness(0, 0, 10, 0) }; identity.Children.Add(Label(host.Name)); identity.Children.Add(Detail(host.Kind)); grid.Children.Add(identity);
            for (int index = 0; index < host.Modules.Count; index++)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition()); var module = ConnectionModuleView(host.Modules[index], snapshot, available);
                Grid.SetColumn(module, index + 1); grid.Children.Add(module);
            }
            Identify(grid, "settings.connections.host." + host.Id, host.Name + " " + host.Kind); connectionHosts.Children.Add(Card(grid));
        }
        foreach (var reading in snapshot?.QuotaDashboard?.Providers ?? [])
        {
            var text = new StackPanel(); text.Children.Add(Label(ProviderName(reading.Provider)));
            string detail = reading.Provider == "deepseek" ? snapshot?.DeepseekConnection?.Status?.Message ?? snapshot?.Wallet?.Dial?.Freshness ?? reading.FiveHour.FreshnessText :
                reading.Status?.Message ?? string.Join(" · ", new[] { reading.FiveHour.SourceText, reading.FiveHour.FreshnessText }.Where(value => !string.IsNullOrEmpty(value)));
            var state = Detail(detail); if (reading.Status?.State == "error") state.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); text.Children.Add(state);
            var action = new StackPanel();
            var quotaActions = reading.Provider == "deepseek" ? snapshot?.DeepseekConnection?.Status?.Actions : reading.Status?.Actions;
            if (quotaActions?.FirstOrDefault(value => value.Enabled) is { } quotaAction)
            {
                var retry = ConnectionButton(quotaAction.Title, "settings.connections.quota." + reading.Provider, available);
                retry.Click += async (_, _) =>
                {
                    if (quotaAction.Kind == "settings") await NavigateAsync(reading.Provider);
                    else if (reading.Provider == "claude" && engine?.LatestSnapshot?.ClaudeConnection?.State is "signedOut" or "workspaceNeeded")
                        await NavigateAsync("claude");
                    else if (reading.Provider == "deepseek") await NavigateAsync("deepseek");
                    else await RunConnectionAction(async () => { if (engine != null) await engine.SendAsync("retryQuota", new { provider = reading.Provider }); });
                };
                action.Children.Add(retry);
            }
            connectionQuotas.Children.Add(Card(Row(text, action, 54)));
        }
    }
    private FrameworkElement ConnectionModuleView(ConnectionModule module, EngineSnapshot? snapshot, bool available)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 8, 0), MinWidth = 120, MaxWidth = 235 };
        stack.Children.Add(Label(ProviderName(module.Provider), 11, FontWeights.SemiBold));
        var status = Detail(module.Label); status.SetResourceReference(TextBlock.ForegroundProperty, Tone(module.Tone)); stack.Children.Add(status);
        if (module.SessionsText.Length > 0) stack.Children.Add(Detail(module.SessionsText));
        var setup = snapshot?.ClaudeRemoteSetups?.FirstOrDefault(row => row.SourceID == module.Key);
        if (module.RetrySetup && setup != null)
        {
            var retry = ConnectionButton(ui.Text("connections.retry"), "settings.connections.setup." + module.Key, available && setup.CanRetry && !setup.InFlight);
            retry.Click += async (_, _) => await RunConnectionAction(async () =>
            {
                var action = ConnectionActions.SetupRetry(engine?.LatestSnapshot, module, setup.Context);
                if (action != null && engine != null) await engine.SendAsync("retryClaudeRemoteSetup", action);
            });
            stack.Children.Add(retry);
        }
        if (module.ReadsQuota)
        {
            var quota = snapshot?.Sources.FirstOrDefault(source => source.Id == module.Id);
            if (quota?.QuotaWindows != null) foreach (var window in quota.QuotaWindows) stack.Children.Add(Detail(window.Label + " · " + window.ValueText + (window.RemainingPercent != null ? "%" : "")));
            if (quota?.QuotaError is string error) { var warning = Detail(error); warning.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); stack.Children.Add(warning); }
            var read = ConnectionButton(ui.Text("windows.connections.read_quota"), "settings.connections.read_quota." + module.Id, available && quota?.QuotaRefreshing != true);
            read.Click += async (_, _) => await RunConnectionAction(async () =>
            {
                var action = ConnectionActions.ReadQuota(engine?.LatestSnapshot, module);
                if (action != null && engine != null) await engine.SendAsync("readConnectionQuota", action);
            });
            stack.Children.Add(read);
        }
        return stack;
    }
    private Button ConnectionButton(string title, string id, bool enabled)
    {
        var button = new Button { Content = title, IsEnabled = enabled, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 5, 0, 0) };
        Identify(button, id, title); connectionActions.Add(button); return button;
    }
    private static string ProviderName(string provider) => provider switch { "codex" => "Codex", "claude" => "Claude", "deepseek" => "DeepSeek", _ => provider };
    private static string Tone(string? tone) => tone switch { "warning" => "SettingsWarning", "success" => "SettingsSuccess", _ => "SettingsSecondary" };
    private async Task RunConnectionAction(Func<Task> action)
    {
        if (sourceClosed || providerConnectionClosed || busy || connectionBusy || session.RequiresRestart || activePane != "connections") return;
        connectionBusy = true; RefreshConnections();
        try { await sourceReady; if (!sourceClosed && !providerConnectionClosed && activePane == "connections" && !session.RequiresRestart) await action(); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { if (!sourceClosed) ShowIssue("windows.connection.refresh_failed"); }
        finally { connectionBusy = false; if (!sourceClosed) RefreshConnections(); }
    }
}
