using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// A module read by the shared local adapter, laid out like the built-in
/// pages: the header switch, Status (local tasks, account, credits), Display
/// (progress ring, turn credits) and the folded data folder.
internal sealed partial class SettingsWindow
{
    private StackPanel? harnessSections;
    private Border? harnessOff;
    private CheckBox? harnessEnabled, harnessProgress, harnessTurnCredits;
    private Button? harnessAutomatic, harnessRefresh, harnessProgressRetry, harnessProgressConnectors;
    private Ellipse? harnessStatusDot, harnessAccountDot;
    private TextBlock? harnessDetection, harnessState, harnessHint, harnessProgressState;
    private TextBlock? harnessAccountState, harnessAccountHelp, harnessCredits, harnessCreditsDetail;
    private Button? harnessAccountSignIn, harnessAccountOptions, harnessUsageGuide;
    private bool refreshingHarness;

    private void ClearHarnessPage()
    {
        harnessSections = null; harnessOff = null;
        harnessEnabled = harnessProgress = harnessTurnCredits = null;
        harnessAutomatic = harnessRefresh = harnessProgressRetry = harnessProgressConnectors = null;
        harnessStatusDot = harnessAccountDot = null;
        harnessDetection = harnessState = harnessHint = harnessProgressState = null;
        harnessAccountState = harnessAccountHelp = harnessCredits = harnessCreditsDetail = null;
        harnessAccountSignIn = harnessAccountOptions = harnessUsageGuide = null;
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

        // Local tasks: one state, with Rescan only while nothing is found, as Codex's CLI row.
        var rescan = new Button { Content = ui.Text("settings.rescan"), Visibility = Visibility.Collapsed }; harnessRefresh = rescan;
        Identify(rescan, id + ".refresh", ui.Text("settings.rescan")); editors.Add(rescan);
        rescan.Click += async (_, _) =>
        {
            refreshingHarness = true; rescan.IsEnabled = false;
            try { await client.SendAsync("refreshLocalHarness", new { provider }); }
            catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (harnessRefresh == rescan) ShowIssue("windows.connection.refresh_failed"); }
            finally { if (harnessRefresh == rescan) { refreshingHarness = false; RefreshHarnessPage(); } }
        };
        harnessHint = Detail("");
        var status = StatusRow(ui.Text("harness.local_tasks"), out var dot, out var state, rescan, harnessHint);
        harnessStatusDot = dot; harnessState = state;
        Identify(state, id + ".status", "");
        var rows = new List<UIElement> { status };
        if (descriptor.ReportsAccountCredits == true)
        {
            rows.Add(BuildHarnessAccountRow(provider, id));
            rows.Add(BuildHarnessCreditsRow(provider, id, descriptor));
        }
        harnessSections.Children.Add(SectionTitle(ui.Text("main.section.status")));
        harnessSections.Children.Add(Card(rows.ToArray()));

        var display = new List<UIElement>();
        if (descriptor.HasTaskProgress == true) display.Add(BuildHarnessProgressRow(client, provider, id, descriptor));
        if (descriptor.ReportsAccountCredits == true || descriptor.ReportsSessionUsage == true)
        {
            var credits = Toggle("harness.turn_credits", "main.info.harness_turn_credits", id + ".turn_credits", out var creditsSwitch);
            harnessTurnCredits = creditsSwitch; editors.Add(creditsSwitch);
            BindToggle(creditsSwitch, (p, value) => p with
            {
                HiddenTurnCredits = value ? p.HiddenTurnCredits.Where(item => item != provider).ToArray()
                    : p.HiddenTurnCredits.Append(provider).Distinct(StringComparer.Ordinal).ToArray()
            });
            display.Add(credits);
        }
        if (display.Count > 0)
        {
            harnessSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
            harnessSections.Children.Add(Card(display.ToArray()));
        }
        if (descriptor.Local == true) harnessSections.Children.Add(Card(ProviderHomeEditor(provider)));
    }

    private Grid BuildHarnessProgressRow(EngineClient client, string provider, string id, EngineModule descriptor)
    {
        string title = ui.Text("main.claude.ring");
        var progress = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
        Identify(progress, id + ".progress", title);
        harnessProgress = progress; editors.Add(progress);
        BindToggle(progress, (p, value) => p with
        {
            DisabledHarnessProgress = value ? p.DisabledHarnessProgress.Where(item => item != provider).ToArray()
                : p.DisabledHarnessProgress.Append(provider).Distinct(StringComparer.Ordinal).ToArray()
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
            if (WindowsConversationApplication.CanOpenConnectors(provider))
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
        string help = ui.Has(provider + ".progress_ring_help") ? ui.Text(provider + ".progress_ring_help") : ui.Text("harness.show_progress_help");
        return InfoRow(title, controls, help, harnessProgressState, id + ".progress");
    }

    /// As Claude's account row: a dot and state, then Sign In, or the account menu once signed in.
    private Grid BuildHarnessAccountRow(string provider, string id)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        harnessAccountDot = new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        trailing.Children.Add(harnessAccountDot);
        harnessAccountState = Label("", 12.5); harnessAccountState.Margin = new Thickness(0, 0, 8, 0); harnessAccountState.VerticalAlignment = VerticalAlignment.Center;
        Identify(harnessAccountState, id + ".account_state", ""); trailing.Children.Add(harnessAccountState);
        var signIn = new Button { Content = ui.Text("welcome.module.sign_in"), Style = (Style)FindResource("SettingsProminentButton") };
        harnessAccountSignIn = signIn; Identify(signIn, id + ".sign_in", ui.Text("welcome.module.sign_in")); editors.Add(signIn); trailing.Children.Add(signIn);
        signIn.Click += async (_, _) => await RunHarnessAccountAsync(() => harnessAccount?.ConnectAsync() ?? Task.CompletedTask);
        var more = new IconGlyph { Symbol = "ellipsis.circle", Width = 16, Height = 16 }; more.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var options = new Button { Content = more, ContentTemplate = null, Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22,
            Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        harnessAccountOptions = options; Identify(options, id + ".account_options", ui.Text("claude.account.options")); editors.Add(options); trailing.Children.Add(options);
        options.Click += (_, _) => OpenHarnessAccountMenu(provider, id);
        harnessAccountHelp = Detail("");
        return InfoRow(ui.Text("harness.account_row"), trailing, detail: harnessAccountHelp, id: id + ".account");
    }

    private void OpenHarnessAccountMenu(string provider, string id)
    {
        if (harnessAccount is not { } account || harnessAccountOptions is not { } anchor) return;
        var menu = new ContextMenu { PlacementTarget = anchor, FontFamily = PacerFonts.Interface };
        MenuItem Item(string key, string suffix, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = ui.Text(key), IsEnabled = enabled }; Identify(item, id + "." + suffix, ui.Text(key));
            item.Click += (_, _) => action(); return item;
        }
        menu.Items.Add(Item("common.refresh", "refresh", () => _ = RunHarnessAccountAsync(account.RefreshAsync)));
        // The bill lives on the site the account belongs to; Automatic follows the app's language.
        var site = new MenuItem { Header = ui.Text("harness.account.site") }; Identify(site, id + ".site", ui.Text("harness.account.site"));
        foreach (var (value, label) in new[] { ("automatic", ui.Text("harness.site.automatic")),
            ("china", ui.Text("harness.site.china").Replace("%@", "workbuddy.cn", StringComparison.Ordinal)),
            ("international", ui.Text("harness.site.international").Replace("%@", "workbuddy.ai", StringComparison.Ordinal)) })
        {
            var choice = new MenuItem { Header = label, IsCheckable = true, IsChecked = session.Current.WorkBuddyAccountSite == value };
            Identify(choice, id + ".site." + value, label);
            choice.Click += async (_, _) =>
            {
                if (value == session.Current.WorkBuddyAccountSite) return;
                await Change(p => p with { WorkBuddyAccountSite = value });
                harnessAccount?.SelectSite(session.Current.UsesWorkBuddyChina(ui.Language == "zh-Hans"));
            };
            site.Items.Add(choice);
        }
        menu.Items.Add(site);
        menu.Items.Add(Item("harness.account.switch", "switch_account", () => _ = RunHarnessAccountAsync(account.ConnectAsync)));
        menu.Items.Add(Item("harness.account.sign_out", "sign_out", () => _ = RunHarnessAccountAsync(account.DisconnectAsync), account.CanDisconnect));
        anchor.ContextMenu = menu; menu.IsOpen = true;
    }

    private async Task RunHarnessAccountAsync(Func<Task> action)
    {
        if (sourceClosed || busy || harnessAccount is not { Busy: false }) return;
        ClearIssue();
        try { await action(); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error)) { if (!sourceClosed) ShowIssue("harness.account.unavailable"); }
        finally { if (!sourceClosed) RefreshAccountCards(); }
    }

    /// What is left, and when the plan resets or a pack expires; the trend lives on History.
    private Grid BuildHarnessCreditsRow(string provider, string id, EngineModule descriptor)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        harnessCredits = Label("", 12.5); harnessCredits.VerticalAlignment = VerticalAlignment.Center;
        harnessCredits.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Identify(harnessCredits, id + ".credits", ""); trailing.Children.Add(harnessCredits);
        if (SettingsPagePolicy.HarnessUsageGuide(provider, descriptor.UsageGuideUrl) is { } guide)
        {
            var link = new Button { Content = ui.Text("harness.account_usage_help"), Style = (Style)FindResource("SettingsLink"), Margin = new Thickness(10, 0, 0, 0) };
            harnessUsageGuide = link; Identify(link, id + ".accountUsage", ui.Text("harness.account_usage_help"));
            link.Click += (_, _) => { if (!SettingsPagePolicy.OpenHarnessUsage(guide, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
            trailing.Children.Add(link);
        }
        harnessCreditsDetail = Detail(""); Identify(harnessCreditsDetail, id + ".credits_detail", "");
        string name = descriptor.DisplayName ?? PaneTitle(provider);
        return InfoRow(ui.Text("harness.credits"), trailing, ui.Text("main.info.harness_credits").Replace("%@", name, StringComparison.Ordinal),
            harnessCreditsDetail, id + ".credits_row");
    }

    private async Task RefreshHarnessProgressConnectionAsync()
    {
        if (demo || !IsActive || engine is not { IsConnectionClosed: false } client ||
            HarnessModule(activePane) is not { Enabled: true, ProgressSetup: "configured", ProgressConnection: not null } module ||
            session.Current.DisabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal)) return;
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
        harnessRefresh!.Visibility = closed || module.Status == "ready" ? Visibility.Collapsed : Visibility.Visible;
        harnessRefresh.IsEnabled = editable && !refreshingHarness;
        RefreshHarnessAccount(editable && module.Enabled);
        bool progressOn = !session.Current.DisabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal);
        if (harnessProgress != null)
        {
            harnessProgress.IsChecked = progressOn;
            harnessProgress.IsEnabled = editable;
        }
        if (harnessTurnCredits != null)
        {
            harnessTurnCredits.IsChecked = !session.Current.HiddenTurnCredits.Contains(module.Provider, StringComparer.Ordinal);
            harnessTurnCredits.IsEnabled = editable;
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
            // Trusting the tool is the one step left to the user.
            harnessProgressConnectors.Visibility = connection is "needsTrust" or "disabled" or "toolDisabled" or "unknown" ? Visibility.Visible : Visibility.Collapsed;
            harnessProgressConnectors.IsEnabled = editable && !demo;
        }
        var (status, hint, tone) = closed ? (ui.Text("windows.connection.closed"), "", "neutral") : HarnessStatus(module);
        SetStatus(harnessStatusDot, harnessState, status, tone);
        SetHarnessText(harnessHint, hint);
        RefreshProviderHome();
    }

    private void RefreshAccountCards()
    {
        if (sourceClosed) return;
        if (harnessAccountState != null)
            RefreshHarnessAccount(!busy && !providerConnectionClosed && HarnessModule(activePane)?.Enabled == true);
        RefreshOverview();
    }

    private void RefreshHarnessAccount(bool editable)
    {
        if (harnessAccountState == null) return;
        var account = harnessAccount;
        bool busyReading = account?.Busy == true, signedIn = account?.Reading != null;
        string state = busyReading ? "harness.account.reading" : signedIn ? "harness.account.signed_in" : "harness.account.signed_out";
        string text = ui.Text(state) + (signedIn && account!.Reading!.Plan is string plan && !busyReading ? " · " + plan : "");
        SetStatus(harnessAccountDot, harnessAccountState, text, signedIn ? "positive" : "neutral");
        bool idle = editable && account is { Busy: false, Available: true };
        harnessAccountSignIn!.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;
        harnessAccountOptions!.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        harnessAccountSignIn.IsEnabled = harnessAccountOptions.IsEnabled = idle;
        string help = account is { Available: false } ? ui.Text("harness.account.runtime")
            : account?.State == "unavailable" ? ui.Text("harness.account.unavailable") : "";
        SetHarnessText(harnessAccountHelp, help);
        if (harnessCredits == null) return;
        if (account?.Reading is { } reading)
        {
            string left = HarnessAccountCard.Fields(ui, "harness.credits.left", HarnessAccountCard.Amount(ui, reading.Remaining));
            harnessCredits.Text = left; AutomationProperties.SetName(harnessCredits, left);
            var details = new List<string>();
            var culture = HarnessAccountCard.Culture(ui);
            string Date(DateTimeOffset value) => value.ToLocalTime().ToString(ui.Language == "zh-Hans" ? "M月d日" : "MMM d", culture);
            if (reading.Cycle is { ResetsAt: { } reset } && reset > DateTimeOffset.UtcNow)
                details.Add(HarnessAccountCard.Fields(ui, "harness.account.cycle_reset", Date(reset)));
            if (reading.Expiration is { } expiring && expiring.At > DateTimeOffset.UtcNow)
                details.Add(HarnessAccountCard.Fields(ui, "harness.account.expiring", HarnessAccountCard.Amount(ui, expiring.Credits), Date(expiring.At)));
            SetHarnessText(harnessCreditsDetail, string.Join(" · ", details));
        }
        else
        {
            harnessCredits.Text = "—"; AutomationProperties.SetName(harnessCredits, ui.Text("harness.account.sign_in"));
            SetHarnessText(harnessCreditsDetail, signedIn || busyReading ? "" : ui.Text("harness.account.sign_in"));
        }
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
}
