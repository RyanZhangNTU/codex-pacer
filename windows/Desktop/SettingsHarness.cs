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
    private TextBlock? harnessAccountState, harnessAccountHelp;
    private StackPanel? harnessCreditsBlock;
    private string harnessCreditsKey = "";
    private Button? harnessAccountSignIn, harnessAccountOptions, harnessUsageGuide;
    private bool refreshingHarness;

    private void ClearHarnessPage()
    {
        harnessSections = null; harnessOff = null;
        harnessEnabled = harnessProgress = harnessTurnCredits = null;
        harnessAutomatic = harnessRefresh = harnessProgressRetry = harnessProgressConnectors = null;
        harnessStatusDot = harnessAccountDot = null;
        harnessDetection = harnessState = harnessHint = harnessProgressState = null;
        harnessAccountState = harnessAccountHelp = null; harnessCreditsBlock = null; harnessCreditsKey = "";
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
            harnessCreditsBlock = new StackPanel(); Identify(harnessCreditsBlock, id + ".credits_block", ui.Text("harness.credits"));
            rows.Add(harnessCreditsBlock);
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
        signIn.Click += async (_, _) => await RunHarnessAccountAsync(() => HarnessAccount?.ConnectAsync() ?? Task.CompletedTask);
        var more = new IconGlyph { Symbol = "ellipsis.circle", Width = 16, Height = 16 }; more.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var options = new Button { Content = more, ContentTemplate = null, Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22,
            Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        harnessAccountOptions = options; Identify(options, id + ".account_options", ui.Text("claude.account.options")); editors.Add(options); trailing.Children.Add(options);
        options.Click += (_, _) => OpenHarnessAccountMenu(provider, id);
        harnessAccountHelp = Detail("");
        return InfoRow(ui.Text("harness.account_row"), trailing, detail: harnessAccountHelp, id: id + ".account");
    }

    /// The page's own module: each credits module keeps its own account and site.
    private HarnessAccountConnection? HarnessAccount => harnessAccounts?[activePane];

    private void OnAccountChanged(string provider) => RefreshAccountCards();

    private void OpenHarnessAccountMenu(string provider, string id)
    {
        if (HarnessAccount is not { } account || harnessAccountOptions is not { } anchor) return;
        var menu = new ContextMenu { PlacementTarget = anchor, FontFamily = PacerFonts.Interface };
        MenuItem Item(string text, string suffix, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = text, IsEnabled = enabled }; Identify(item, id + "." + suffix, text);
            item.Click += (_, _) => action(); return item;
        }
        menu.Items.Add(Item(ui.Text("common.refresh"), "refresh", () => _ = RunHarnessAccountAsync(account.RefreshAsync)));
        if (SettingsPagePolicy.HarnessUsageGuide(provider, HarnessModule(provider)?.UsageGuideUrl) is { } guide)
            menu.Items.Add(Item(ui.Text("harness.account_usage_help"), "usage",
                () => { if (!SettingsPagePolicy.OpenHarnessUsage(guide, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); }));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(ui.Text("harness.account.switch"), "switch_account", () => _ = RunHarnessAccountAsync(account.ConnectAsync)));
        menu.Items.Add(Item(ui.Text("harness.account.sign_out"), "sign_out", () => _ = RunHarnessAccountAsync(account.DisconnectAsync), account.CanDisconnect));
        anchor.ContextMenu = menu; menu.IsOpen = true;
    }

    private async Task RunHarnessAccountAsync(Func<Task> action)
    {
        if (sourceClosed || busy || HarnessAccount is not { Busy: false }) return;
        ClearIssue();
        try { await action(); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error)) { if (!sourceClosed) ShowIssue("harness.account.unavailable"); }
        finally { if (!sourceClosed) RefreshAccountCards(); }
    }

    /// Core's dial beside the month, extra and total lines, then the breakdown by
    /// how each kind of credit behaves, and the service's own usage page.
    private void RefreshHarnessCredits(string provider, HarnessAccountConnection? account)
    {
        if (harnessCreditsBlock == null) return;
        var credits = engine?.LatestSnapshot?.AccountCredits?.FirstOrDefault(value => value.Provider == provider);
        var presentation = account?.Reading == null ? null : credits?.Presentation;
        string key = System.Text.Json.JsonSerializer.Serialize(new { presentation, stale = credits?.Stale, state = account?.State, busy = account?.Busy, ui.Language });
        if (key == harnessCreditsKey) return;
        harnessCreditsKey = key;
        foreach (UIElement child in harnessCreditsBlock.Children) PageAccessibility.Retire(child);
        harnessCreditsBlock.Children.Clear();
        string id = "settings." + provider;
        if (presentation == null)
        {
            var empty = Label(account?.Busy == true ? ui.Text("harness.account.reading") : ui.Text("harness.account.sign_in"), 12.5);
            empty.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); Identify(empty, id + ".credits", empty.Text);
            harnessCreditsBlock.Children.Add(InfoRow(ui.Text("harness.credits"), empty, id: id + ".credits_row"));
            // Where WorkBuddy shows usage helps before signing in too.
            AddUsageGuide();
            return;
        }
        var top = new Grid { Margin = new Thickness(14, 12, 14, 12) };
        top.ColumnDefinitions.Add(new() { Width = new GridLength(104) }); top.ColumnDefinitions.Add(new() { Width = new GridLength(18) }); top.ColumnDefinitions.Add(new());
        var dial = new QuotaDial(provider, null, null, dialSize: 104, credits: presentation.Dial, creditsText: ui, creditsStale: credits?.Stale == true)
            { Width = 104, Height = 104, VerticalAlignment = VerticalAlignment.Center };
        Identify(dial, id + ".credits_dial", presentation.Dial.AccessibilityLabel);
        top.Children.Add(dial);
        var lines = new Grid { VerticalAlignment = VerticalAlignment.Center };
        lines.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); lines.ColumnDefinitions.Add(new());
        for (int index = 0; index < presentation.Lines.Count; index++)
        {
            var line = presentation.Lines[index];
            lines.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var label = Label(line.Label, 12.5); label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            label.Margin = new Thickness(0, 3, 12, 3); Grid.SetRow(label, index); lines.Children.Add(label);
            var value = new WrapPanel { Margin = new Thickness(0, 3, 0, 3), VerticalAlignment = VerticalAlignment.Center };
            var amount = Label(line.Value, 12.5, FontWeights.SemiBold); value.Children.Add(amount);
            if (line.Detail is string detail)
            {
                var note = Label(" · " + detail, 12.5);
                note.SetResourceReference(TextBlock.ForegroundProperty, line.Warns ? "SettingsWarning" : "SettingsSecondary");
                value.Children.Add(note);
            }
            // The plan's name sits with the month's credits, as on WorkBuddy's own page.
            if (index == 0 && presentation.Plan is string plan)
            {
                var badge = new Border { CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                badge.SetResourceReference(Border.BackgroundProperty, "SettingsAccentSoft");
                badge.Child = Label(plan, 11.5, FontWeights.SemiBold); value.Children.Add(badge);
            }
            Identify(value, id + ".credits_line" + index, line.Label + " " + line.Value + (line.Detail is string spoken ? " · " + spoken : ""));
            Grid.SetRow(value, index); Grid.SetColumn(value, 1); lines.Children.Add(value);
        }
        Grid.SetColumn(lines, 2); top.Children.Add(lines);
        harnessCreditsBlock.Children.Add(top);
        if (presentation.Sections.Count > 0)
        {
            var info = InfoBox(ui.Text("credits.details_info")); info.Margin = new Thickness(14, 0, 14, 8);
            var heading = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 0, 14, 2) };
            var title = Label(ui.Text("credits.details"), 12, FontWeights.SemiBold); title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            heading.Children.Add(title); heading.Children.Add(InfoButton(ui.Text("credits.details"), info, id + ".credits_details"));
            harnessCreditsBlock.Children.Add(heading); harnessCreditsBlock.Children.Add(info);
            foreach (var section in presentation.Sections)
            {
                var caption = Label(section.Title, 11.5); caption.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                caption.Margin = new Thickness(14, 6, 14, 2); harnessCreditsBlock.Children.Add(caption);
                foreach (var row in section.Rows)
                {
                    var line = new Grid { Margin = new Thickness(14, 0, 14, 0), MinHeight = 32 };
                    line.ColumnDefinitions.Add(new()); line.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); line.ColumnDefinitions.Add(new() { Width = new GridLength(128) });
                    var name = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                    name.Children.Add(Label(row.Name, 12.5));
                    if (row.Chip is string chip)
                    {
                        var mark = new Border { CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0) };
                        mark.SetResourceReference(Border.BackgroundProperty, "SettingsNoticeFill");
                        var chipText = Label(chip, 11, FontWeights.SemiBold); chipText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsNoticeText");
                        mark.Child = chipText; name.Children.Add(mark);
                    }
                    line.Children.Add(name);
                    var amount = Label(row.Amount, 12.5); amount.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(amount, 1); line.Children.Add(amount);
                    var date = Label(row.Date ?? "", 12); date.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                    date.HorizontalAlignment = HorizontalAlignment.Right; date.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(date, 2); line.Children.Add(date);
                    Identify(line, id + ".credits_" + row.Kind, row.Name + " " + row.Amount + (row.Date is string when ? " · " + when : "") + (row.Chip is string soon ? " · " + soon : ""));
                    harnessCreditsBlock.Children.Add(line);
                }
            }
        }
        AddUsageGuide();

        void AddUsageGuide()
        {
            if (SettingsPagePolicy.HarnessUsageGuide(provider, HarnessModule(provider)?.UsageGuideUrl) is not { } guide) return;
            var link = new Button { Content = ui.Text("harness.account_usage_help"), Style = (Style)FindResource("SettingsLink"),
                HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(14, 6, 14, 10) };
            harnessUsageGuide = link; Identify(link, id + ".accountUsage", ui.Text("harness.account_usage_help"));
            link.Click += (_, _) => { if (!SettingsPagePolicy.OpenHarnessUsage(guide, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
            harnessCreditsBlock!.Children.Add(link);
        }
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
        var account = HarnessAccount;
        bool busyReading = account?.Busy == true, signedIn = account?.Reading != null;
        string state = busyReading ? "harness.account.reading" : signedIn ? "harness.account.signed_in" : "harness.account.signed_out";
        SetStatus(harnessAccountDot, harnessAccountState, ui.Text(state), signedIn ? "positive" : "neutral");
        bool idle = editable && account is { Busy: false, Available: true };
        harnessAccountSignIn!.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;
        harnessAccountOptions!.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        harnessAccountSignIn.IsEnabled = harnessAccountOptions.IsEnabled = idle;
        string help = account is { Available: false } ? ui.Text("harness.account.runtime")
            : account?.State == "unavailable" ? ui.Text("harness.account.unavailable") : "";
        SetHarnessText(harnessAccountHelp, help);
        RefreshHarnessCredits(activePane, account);
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
