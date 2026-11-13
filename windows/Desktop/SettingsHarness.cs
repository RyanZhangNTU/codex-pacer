using System;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private StackPanel? harnessSections;
    private Border? harnessOff;
    private CheckBox? harnessEnabled, harnessProgress;
    private Button? harnessAutomatic, harnessRefresh, harnessProgressRetry, harnessProgressConnectors;
    private Ellipse? harnessStatusDot;
    private TextBlock? harnessDetection, harnessState, harnessHint, harnessContext, harnessCredits, harnessNoUsage;
    private TextBlock? harnessProgressState;
    private Border? harnessAccountBody;
    private Button? harnessAccountConnect, harnessAccountRefresh, harnessAccountDisconnect;
    private ComboBox? harnessAccountSite;
    private bool refreshingHarness;

    private void ClearHarnessPage()
    {
        harnessSections = null; harnessOff = null;
        harnessEnabled = harnessProgress = null;
        harnessAutomatic = harnessRefresh = harnessProgressRetry = harnessProgressConnectors = null;
        harnessStatusDot = null;
        harnessDetection = harnessState = harnessHint = harnessContext = harnessCredits = harnessNoUsage = null;
        harnessProgressState = null;
        harnessAccountBody = null; harnessAccountConnect = harnessAccountRefresh = harnessAccountDisconnect = null;
        harnessAccountSite = null;
        refreshingHarness = false;
    }

    private void BuildHarnessPage(string provider)
    {
        if (engine is not { } client || HarnessModule(provider) is not { } descriptor) return;
        string id = "settings." + provider;
        SetPaneHeader(ProviderHeader(provider, out var detection, out var enabled, out var automatic));
        harnessDetection = detection; harnessEnabled = enabled; harnessAutomatic = automatic;
        Identify(enabled, id + ".enabled", PaneTitle(provider)); editors.Add(enabled);
        BindToggle(enabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { [provider] = value ? "enabled" : "disabled" } });
        Identify(automatic, id + ".automatic", ui.Text("provider.restore_automatic")); editors.Add(automatic);
        automatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { [provider] = "automatic" } });
        harnessOff = ModuleOffCard(); form.Children.Add(harnessOff);
        harnessSections = new StackPanel(); form.Children.Add(harnessSections);

        var refresh = new Button { Content = ui.Text("common.refresh") }; harnessRefresh = refresh;
        Identify(refresh, id + ".refresh", ui.Text("common.refresh")); editors.Add(refresh);
        refresh.Click += async (_, _) =>
        {
            refreshingHarness = true; refresh.IsEnabled = false;
            try { await client.SendAsync("refreshLocalHarness", new { provider }); }
            catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (harnessRefresh == refresh) ShowIssue("windows.connection.refresh_failed"); }
            finally { if (harnessRefresh == refresh) { refreshingHarness = false; RefreshHarnessPage(); } }
        };
        harnessHint = Detail("");
        var status = StatusRow(ui.Text("harness.local_tasks"), out var dot, out var state, refresh, harnessHint);
        harnessStatusDot = dot; harnessState = state;
        Identify(state, id + ".status", "");
        harnessSections.Children.Add(SectionTitle(ui.Text("main.section.status")));
        harnessSections.Children.Add(Card(status));

        if (descriptor.ReportsAccountCredits == true)
        {
            harnessSections.Children.Add(SectionTitle(ui.Text("harness.account.title")));
            var account = new StackPanel();
            harnessAccountBody = new Border { Padding = new Thickness(14, 10, 14, 8) };
            account.Children.Add(harnessAccountBody);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            Button AccountButton(string key, string suffix, Func<Task> action)
            {
                var button = new Button { Content = ui.Text(key), Margin = new Thickness(6, 0, 0, 0) };
                Identify(button, id + ".account." + suffix, ui.Text(key)); actions.Children.Add(button);
                button.Click += async (_, _) => await action(); return button;
            }
            harnessAccountConnect = AccountButton("harness.account.connect", "connect", () => harnessAccount?.ConnectAsync() ?? Task.CompletedTask);
            harnessAccountRefresh = AccountButton("common.refresh", "refresh", () => harnessAccount?.RefreshAsync() ?? Task.CompletedTask);
            harnessAccountDisconnect = AccountButton("harness.account.disconnect", "disconnect", () => harnessAccount?.DisconnectAsync() ?? Task.CompletedTask);
            account.Children.Add(InfoRow(ui.Text("harness.account.connection"), actions));
            var site = new ComboBox { ItemsSource = new[] { ui.Text("provider.automatic"), "workbuddy.cn", "workbuddy.ai" }, MinWidth = 124 };
            harnessAccountSite = site; Identify(site, id + ".account.site", ui.Text("harness.account.site"));
            site.SelectedIndex = session.Current.WorkBuddyAccountSite == "china" ? 1 : session.Current.WorkBuddyAccountSite == "international" ? 2 : 0;
            site.SelectionChanged += async (_, _) =>
            {
                if (site != harnessAccountSite || site.SelectedIndex is < 0 or > 2) return;
                string value = site.SelectedIndex == 1 ? "china" : site.SelectedIndex == 2 ? "international" : "automatic";
                if (value == session.Current.WorkBuddyAccountSite) return;
                await Change(p => p with { WorkBuddyAccountSite = value });
                harnessAccount?.SelectSite(session.Current.UsesWorkBuddyChina(ui.Language == "zh-Hans"));
                if (site == harnessAccountSite)
                    site.SelectedIndex = session.Current.WorkBuddyAccountSite == "china" ? 1 : session.Current.WorkBuddyAccountSite == "international" ? 2 : 0;
            };
            account.Children.Add(InfoRow(ui.Text("harness.account.site"), site));
            harnessSections.Children.Add(Card(account));
        }
        var usageGuide = SettingsPagePolicy.HarnessUsageGuide(provider, descriptor.UsageGuideUrl);
        if (descriptor.ReportsSessionUsage == true || descriptor.Usage != null || usageGuide != null)
        {
            harnessContext = Detail(""); harnessCredits = Detail(""); harnessNoUsage = Detail(ui.Text("harness.no_usage"));
            var readings = new StackPanel { Margin = new Thickness(14, 10, 14, 10) };
            readings.Children.Add(harnessContext); readings.Children.Add(harnessCredits); readings.Children.Add(harnessNoUsage);
            Identify(harnessContext, id + ".context", ""); Identify(harnessCredits, id + ".credits", "");
            harnessSections.Children.Add(SectionTitle(ui.Text("harness.usage")));
            var usageCard = new StackPanel(); usageCard.Children.Add(readings);
            if (usageGuide != null)
            {
                var help = new Button { Content = ui.Text("main.overview.open"), Style = (Style)FindResource("SettingsLink") };
                Identify(help, id + ".accountUsage", ui.Text("harness.account_usage_help"));
                help.Click += (_, _) => { if (!SettingsPagePolicy.OpenHarnessUsage(usageGuide, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
                usageCard.Children.Add(InfoRow(ui.Text("harness.account_usage_help"), help));
            }
            harnessSections.Children.Add(Card(usageCard));
        }

        var display = new StackPanel();
        if (descriptor.HasTaskProgress == true)
        {
            string title = ui.Text("main.claude.ring");
            var progress = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
            Identify(progress, id + ".progress", title);
            harnessProgress = progress; editors.Add(progress);
            BindToggle(progress, (p, value) => p with
            {
                EnabledHarnessProgress = value ? p.EnabledHarnessProgress.Append(provider).Distinct(StringComparer.Ordinal).ToArray()
                    : p.EnabledHarnessProgress.Where(item => item != provider).ToArray()
            });
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            if (descriptor.ProgressConnector == true)
            {
                harnessProgressState = Detail("");
                Identify(harnessProgressState, id + ".progress_state", "");
                var retry = new Button { Content = ui.Text("connections.retry"), Margin = new Thickness(0, 0, 8, 0) };
                harnessProgressRetry = retry; editors.Add(retry);
                Identify(retry, id + ".progress_retry", ui.Text("connections.retry"));
                retry.Click += async (_, _) =>
                {
                    try { await client.SendAsync("retryHarnessProgressSetup", new { provider }); }
                    catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
                    { if (harnessProgressRetry == retry) ShowIssue("harness.progress_state.failed"); }
                };
                controls.Children.Add(retry);
                if (provider == "workbuddy")
                {
                    var connectors = new Button { Content = ui.Text("harness.progress_state.open_connectors"), Margin = new Thickness(0, 0, 8, 0) };
                    harnessProgressConnectors = connectors;
                    Identify(connectors, id + ".progress_connectors", ui.Text("harness.progress_state.open_connectors"));
                    connectors.Click += async (_, _) =>
                    {
                        if (!await WindowsConversationApplication.OpenProgressConnectorsAsync(provider) && harnessProgressConnectors == connectors)
                            ShowIssue("harness.progress_state.open_failed");
                    };
                    controls.Children.Add(connectors);
                }
            }
            controls.Children.Add(progress);
            display.Children.Add(InfoRow(title, controls, ui.Text("harness.show_progress_help"), harnessProgressState, id + ".progress"));
        }
        if (display.Children.Count > 0)
        {
            harnessSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
            harnessSections.Children.Add(Card(display));
        }
    }

    private async Task RefreshHarnessProgressConnectionAsync()
    {
        if (demo || !IsActive || engine is not { IsConnectionClosed: false } client ||
            HarnessModule(activePane) is not { Enabled: true, ProgressSetup: "configured", ProgressConnection: not null } module ||
            !session.Current.EnabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal)) return;
        try { await client.SendAsync("refreshHarnessProgressConnection", new { provider = module.Provider }); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { }
    }

    private void RefreshHarnessPage()
    {
        if (harnessEnabled == null || HarnessModule(activePane) is not { } module) return;
        bool closed = providerConnectionClosed || engine?.IsConnectionClosed != false;
        bool editable = !closed && !busy && !session.RequiresRestart;
        harnessEnabled.IsChecked = module.Enabled;
        harnessEnabled.IsEnabled = editable;
        string detection = ui.Text(module.Installed switch { true => "windows.provider.detected", false => "windows.provider.not_detected", _ => "provider.state.searching" });
        harnessDetection!.Text = module.Mode == "automatic" ? detection + " · " + ui.Text("provider.automatic") : detection;
        harnessAutomatic!.Visibility = module.Mode == "automatic" ? Visibility.Collapsed : Visibility.Visible;
        harnessAutomatic.IsEnabled = editable;
        harnessOff!.Visibility = !closed && !module.Enabled ? Visibility.Visible : Visibility.Collapsed;
        harnessSections!.Visibility = closed || module.Enabled ? Visibility.Visible : Visibility.Collapsed;
        harnessRefresh!.IsEnabled = editable && !refreshingHarness;
        RefreshAccountCard(editable && module.Enabled);
        bool progressOn = session.Current.EnabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal);
        if (harnessProgress != null)
        {
            harnessProgress.IsChecked = progressOn;
            harnessProgress.IsEnabled = editable;
        }
        string? setup = closed ? null : module.ProgressSetup;
        string? connection = setup == "configured" && progressOn ? module.ProgressConnection : null;
        bool retrySetup = setup is "missingHome" or "conflict" or "failed" || connection == "missing";
        string? progressKey = setup switch
        {
            "settingUp" => "harness.progress_state.setting_up",
            "configured" when progressOn => connection switch
            {
                "needsTrust" => "harness.progress_state.needs_trust",
                "trusted" => "harness.progress_state.trusted",
                "disabled" => "harness.progress_state.disabled",
                "toolDisabled" => "harness.progress_state.tool_disabled",
                "missing" => "harness.progress_state.missing",
                "unknown" => "harness.progress_state.unknown",
                _ => "harness.progress_state.configured"
            },
            "missingHome" => "harness.progress_state.missing_home",
            "conflict" => "harness.progress_state.conflict",
            "failed" => progressOn ? "harness.progress_state.failed" : "harness.progress_state.cleanup_failed",
            _ => null
        };
        SetHarnessText(harnessProgressState, progressKey == null ? "" : ui.Text(progressKey));
        if (harnessProgressRetry != null)
        {
            harnessProgressRetry.Visibility = retrySetup ? Visibility.Visible : Visibility.Collapsed;
            harnessProgressRetry.IsEnabled = editable && retrySetup;
        }
        if (harnessProgressConnectors != null)
        {
            harnessProgressConnectors.Visibility = connection != null && connection != "missing" ? Visibility.Visible : Visibility.Collapsed;
            harnessProgressConnectors.IsEnabled = editable && !demo;
        }
        var (status, hint, tone) = closed ? (ui.Text("windows.connection.closed"), "", "neutral") : HarnessStatus(module);
        SetStatus(harnessStatusDot, harnessState, status, tone);
        SetHarnessText(harnessHint, hint);
        var (context, credits) = closed ? ("", "") : HarnessUsageValues(module);
        SetHarnessText(harnessContext, context);
        SetHarnessText(harnessCredits, credits);
        if (harnessNoUsage != null) harnessNoUsage.Visibility = context.Length == 0 && credits.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshAccountCards()
    {
        if (sourceClosed) return;
        if (harnessAccountBody != null)
            RefreshAccountCard(!busy && !providerConnectionClosed && HarnessModule(activePane)?.Enabled == true);
        RefreshOverview();
    }

    private void RefreshAccountCard(bool editable)
    {
        if (harnessAccountBody == null) return;
        var key = (harnessAccount?.Reading, harnessAccount?.State, harnessAccount?.Busy);
        if (harnessAccountBody.Child == null || !Equals(key, harnessAccountBody.Tag))
        {
            harnessAccountBody.Tag = key;
            harnessAccountBody.Child = HarnessAccountCard.Build(ui, harnessAccount, false, "settings." + activePane + ".account");
        }
        bool idle = editable && harnessAccount is { Busy: false, Available: true };
        bool connected = harnessAccount?.Reading != null;
        harnessAccountConnect!.IsEnabled = idle;
        harnessAccountConnect.Content = ui.Text(connected ? "harness.account.switch" : "harness.account.connect");
        AutomationProperties.SetName(harnessAccountConnect, (string)harnessAccountConnect.Content);
        harnessAccountRefresh!.IsEnabled = idle;
        harnessAccountDisconnect!.IsEnabled = idle && harnessAccount?.CanDisconnect == true;
        harnessAccountSite!.IsEnabled = editable && harnessAccount?.Busy != true;
    }

    private static void SetHarnessText(TextBlock? label, string text)
    {
        if (label == null) return;
        if (label.Text != text) { label.Text = text; AutomationProperties.SetName(label, text); }
        label.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private (string Status, string Hint, string Tone) HarnessStatus(EngineModule module) => module.Status switch
    {
        "ready" => (ui.Text("harness.ready"), "", "positive"),
        "missing" when module.Installed == false => (ui.Text("harness.not_installed"), "", "attention"),
        "missing" => (ui.Text("harness.waiting_for_tasks"), ui.Text("harness.missing"), "neutral"),
        "incompatible" => (ui.Text("harness.unsupported_format"), ui.Text("harness.incompatible"), "attention"),
        "unavailable" => (ui.Text("harness.read_failed"), ui.Text("harness.unavailable"), "attention"),
        _ when module.Installed == false => (ui.Text("harness.not_installed"), "", "attention"),
        _ => (ui.Text("provider.state.searching"), "", "neutral")
    };

    private (string Context, string Credits) HarnessUsageValues(EngineModule module)
    {
        if (module is not { Status: "ready", Usage: { } usage }) return ("", "");
        var culture = CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US");
        string context = usage.ContextUsed is int used && usage.ContextCapacity is int capacity && used >= 0 && capacity > 0
            ? ui.Text("harness.context").Replace("%1$@", used.ToString("N0", culture), StringComparison.Ordinal)
                .Replace("%2$@", capacity.ToString("N0", culture), StringComparison.Ordinal) : "";
        string credits = usage.SessionCredits is double spent && double.IsFinite(spent) && spent >= 0
            ? ui.Text("harness.session_credits").Replace("%@", spent.ToString("0.##", culture), StringComparison.Ordinal) : "";
        return (context, credits);
    }
}
