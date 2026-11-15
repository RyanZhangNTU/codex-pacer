using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// A module read by the shared local adapter, laid out like the built-in
/// pages: the header switch, Status (local tasks, account, credits), Display
/// (progress ring, turn credits) and the folded data folder.
internal sealed partial class SettingsWindow
{
    private StackPanel? harnessSections;
    private Border? harnessOff;
    private CheckBox? harnessEnabled, harnessProgress, harnessTurnCredits;
    private Button? harnessAutomatic, harnessRefresh;
    private Ellipse? harnessStatusDot, harnessAccountDot;
    private TextBlock? harnessDetection, harnessState, harnessHint;
    // The progress ring's step card, for a module whose app must trust Pacer's tool.
    private Border? harnessProgressChip;
    private TextBlock? harnessProgressChipText, harnessProgressInfo;
    private StackPanel? harnessProgressBody;
    private string harnessProgressKey = "";
    private DispatcherTimer? harnessProgressPoll;
    private TextBlock? harnessAccountState, harnessAccountHelp;
    private StackPanel? harnessCreditsBlock;
    private string harnessCreditsKey = "";
    private Button? harnessAccountSignIn, harnessAccountOptions, harnessUsageGuide;
    private bool refreshingHarness;

    private void ClearHarnessPage()
    {
        harnessSections = null; harnessOff = null;
        harnessEnabled = harnessProgress = harnessTurnCredits = null;
        harnessAutomatic = harnessRefresh = null;
        harnessStatusDot = harnessAccountDot = null;
        harnessDetection = harnessState = harnessHint = null;
        harnessProgressPoll?.Stop(); harnessProgressPoll = null;
        harnessProgressChip = null; harnessProgressChipText = harnessProgressInfo = null; harnessProgressBody = null; harnessProgressKey = "";
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

    /// The progress ring switch. A module whose app must trust Pacer's tool also
    /// gets Core's step card under it, until the app has reported progress.
    private UIElement BuildHarnessProgressRow(EngineClient client, string provider, string id, EngineModule descriptor)
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
        string help = descriptor.ProgressGuide?.Info
            ?? (ui.Has(provider + ".progress_ring_help") ? ui.Text(provider + ".progress_ring_help") : ui.Text("harness.show_progress_help"));
        if (descriptor.ProgressConnector != true) return InfoRow(title, progress, help, id: id + ".progress");
        var trailing = new StackPanel { Orientation = Orientation.Horizontal };
        harnessProgressChipText = Label("", 11.5, FontWeights.SemiBold);
        harnessProgressChip = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center, Child = harnessProgressChipText, Visibility = Visibility.Collapsed };
        Identify(harnessProgressChip, id + ".progress_chip", "");
        trailing.Children.Add(harnessProgressChip); trailing.Children.Add(progress);
        var row = InfoRow(title, trailing, help, id: id + ".progress");
        harnessProgressInfo = row.Children.OfType<Border>().FirstOrDefault(box => Grid.GetRow(box) == 1)?.Child as TextBlock;
        harnessProgressBody = new StackPanel { Margin = new Thickness(14, 0, 14, 0), Visibility = Visibility.Collapsed };
        Identify(harnessProgressBody, id + ".progress_guide", title);
        // While the card waits on the app, it checks again every few seconds, so
        // trusting the tool in WorkBuddy beside Pacer ticks the step by itself.
        var poll = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(3) };
        poll.Tick += async (_, _) =>
        {
            if (harnessProgressPoll != poll || !IsVisible) { poll.Stop(); return; }
            await RefreshHarnessProgressConnectionAsync(polling: true);
        };
        harnessProgressPoll = poll;
        var panel = new StackPanel(); panel.Children.Add(row); panel.Children.Add(harnessProgressBody);
        return panel;
    }

    /// Draws Core's guide: the chip beside the switch, then the steps, or one
    /// line and its action for a problem. Explanations stay behind the ⓘ.
    internal void RefreshHarnessProgressGuide(string provider, HarnessProgressGuide? guide, bool editable)
    {
        if (harnessProgressBody == null) return;
        string id = "settings." + provider;
        if (harnessProgressChip != null && harnessProgressChipText != null)
        {
            harnessProgressChip.Visibility = guide == null ? Visibility.Collapsed : Visibility.Visible;
            string chip = guide == null ? "" : guide.Tone == "success" ? "\u2713 " + guide.Chip : guide.Chip;
            harnessProgressChipText.Text = chip; AutomationProperties.SetName(harnessProgressChip, chip);
            var (fill, ink) = guide?.Tone switch
            {
                "attention" => ("SettingsNoticeFill", "SettingsNoticeText"),
                "info" => ("SettingsChipOn", "SettingsChipOnText"),
                "success" => ("SettingsSuccessFill", "SettingsSuccessText"),
                "error" => ("SettingsErrorFill", "SettingsErrorText"),
                _ => ("SettingsFill", "SettingsSecondary")
            };
            harnessProgressChip.SetResourceReference(Border.BackgroundProperty, fill);
            harnessProgressChipText.SetResourceReference(TextBlock.ForegroundProperty, ink);
        }
        if (harnessProgressInfo != null && guide != null) harnessProgressInfo.Text = guide.Info;
        string key = System.Text.Json.JsonSerializer.Serialize(new { guide, editable, ui.Language });
        if (key == harnessProgressKey) return;
        harnessProgressKey = key;
        foreach (UIElement child in harnessProgressBody.Children) PageAccessibility.Retire(child);
        harnessProgressBody.Children.Clear();
        bool shown = guide != null && (guide.Steps.Count > 0 || guide.Line != null);
        harnessProgressBody.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;

        Button? Action()
        {
            if (guide!.Action is not string action || guide.ActionTitle is not string title) return null;
            var button = new Button { Content = title, IsEnabled = editable && !demo, Margin = new Thickness(0, 0, 10, 0) };
            if (action != "retry") button.Style = (Style)FindResource("SettingsProminentButton");
            Identify(button, id + ".progress_action", title); editors.Add(button);
            button.Click += async (_, _) =>
            {
                bool done = action switch
                {
                    "openConnectors" => await WindowsConversationApplication.OpenProgressConnectorsAsync(provider),
                    "openApp" => await WindowsConversationApplication.OpenApplicationAsync(provider),
                    _ => await RetryHarnessProgressAsync(provider)
                };
                if (!done && harnessProgressBody != null) ShowIssue(action == "retry" ? "harness.progress_state.failed" : "harness.progress_state.open_failed");
            };
            return button;
        }
        UIElement ActionRow()
        {
            var row = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            if (Action() is { } button) row.Children.Add(button);
            if (guide!.Waiting)
            {
                var waiting = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var glyph = new IconGlyph { Symbol = "clock", Width = 13, Height = 13, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
                glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
                var text = Label(guide.WaitingText ?? ui.Text("progress_guide.waiting"), 12); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                text.VerticalAlignment = VerticalAlignment.Center;
                waiting.Children.Add(glyph); waiting.Children.Add(text);
                Identify(waiting, id + ".progress_waiting", text.Text);
                row.Children.Add(waiting);
            }
            return row;
        }

        if (guide!.Steps.Count == 0)
        {
            var problem = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
            var line = Label(guide.Line!, 12.5); line.TextWrapping = TextWrapping.Wrap;
            Identify(line, id + ".progress_line", guide.Line!); problem.Children.Add(line);
            problem.Children.Add(ActionRow());
            harnessProgressBody.Children.Add(problem);
            return;
        }
        for (int index = 0; index < guide.Steps.Count; index++)
        {
            var step = guide.Steps[index];
            var line = new Grid { Margin = new Thickness(0, index == 0 ? 0 : 4, 0, index == guide.Steps.Count - 1 ? 12 : 4) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            line.ColumnDefinitions.Add(new ColumnDefinition());
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var mark = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 1, 0, 0) };
            var number = new TextBlock { FontSize = 11, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Text = step.State == "done" ? "\u2713" : (index + 1).ToString(System.Globalization.CultureInfo.CurrentCulture) };
            switch (step.State)
            {
                case "done": mark.SetResourceReference(Border.BackgroundProperty, "SettingsSuccess"); number.Foreground = Brushes.White; break;
                case "current": mark.SetResourceReference(Border.BackgroundProperty, "SettingsAccent"); number.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSelectionText"); break;
                default: mark.BorderThickness = new Thickness(1.5); mark.SetResourceReference(Border.BorderBrushProperty, "SettingsDisabled"); number.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); break;
            }
            mark.Child = number; line.Children.Add(mark);
            var body = new StackPanel(); Grid.SetColumn(body, 1);
            var title = Label(step.Title, 13, step.State == "current" ? FontWeights.SemiBold : FontWeights.Normal); title.TextWrapping = TextWrapping.Wrap;
            title.SetResourceReference(TextBlock.ForegroundProperty, step.State switch { "done" => "SettingsSecondary", "current" => "SettingsPrimary", _ => "SettingsDisabled" });
            body.Children.Add(title);
            if (step.State == "current" && (guide.Action != null || guide.Waiting)) body.Children.Add(ActionRow());
            line.Children.Add(body);
            if (step.State == "current" && guide.ShowsTrustCard)
            {
                var card = TrustCard(provider); Grid.SetColumn(card, 2); line.Children.Add(card);
            }
            Identify(line, id + ".progress_step" + index, step.Title);
            AutomationProperties.SetItemStatus(line, ui.Text("progress_guide.state." + step.State));
            harnessProgressBody.Children.Add(line);
        }
    }

    /// A small picture of the app's own trust card, so people know what to click there.
    private DecorativeBorder TrustCard(string provider)
    {
        var stack = new StackPanel();
        var trail = Label(ui.Text("progress_guide.trust_card.path"), 10.5); trail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        trail.Margin = new Thickness(0, 0, 0, 7); stack.Children.Add(trail);
        var item = new Border { CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1), Padding = new Thickness(9, 7, 9, 8) };
        item.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator"); item.SetResourceReference(Border.BackgroundProperty, "SettingsCard");
        var lines = new StackPanel();
        var name = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 3) };
        name.Children.Add(new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Color.FromRgb(48, 176, 199)), Margin = new Thickness(0, 0, 6, 0) });
        name.Children.Add(Label("pacer_progress", 11.5, FontWeights.SemiBold));
        lines.Children.Add(name);
        var caption = Label(ui.Text("progress_guide.trust_card.caption"), 10.5); caption.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); lines.Children.Add(caption);
        var detail = Label(ui.Text("progress_guide.trust_card.detail"), 11); detail.TextWrapping = TextWrapping.Wrap; detail.Margin = new Thickness(0, 2, 0, 6); lines.Children.Add(detail);
        var trust = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 3, 12, 4), HorizontalAlignment = HorizontalAlignment.Right, BorderThickness = new Thickness(2) };
        trust.Background = new SolidColorBrush(PacerPalette.BrandColor(provider));
        trust.SetResourceReference(Border.BorderBrushProperty, "SettingsChipOnStroke");
        trust.Child = new TextBlock { Text = ui.Text("progress_guide.trust_card.button"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White };
        lines.Children.Add(trust);
        item.Child = lines; stack.Children.Add(item);
        var frame = new DecorativeBorder { Width = 236, Margin = new Thickness(14, 0, 0, 0), CornerRadius = new CornerRadius(9), Padding = new Thickness(9), Child = stack, VerticalAlignment = VerticalAlignment.Top };
        frame.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        // A picture only: the step's title and button carry the meaning.
        return frame;
    }

    private async Task<bool> RetryHarnessProgressAsync(string provider)
    {
        if (engine is not { IsConnectionClosed: false } client) return false;
        try { await client.SendAsync("retryHarnessProgressSetup", new { provider }); return true; }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { return false; }
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

    /// Checks the app's trust again: when Settings comes forward, and every few
    /// seconds while the step card waits on the app.
    private async Task RefreshHarnessProgressConnectionAsync(bool polling = false)
    {
        if (demo || (!polling && !IsActive) || engine is not { IsConnectionClosed: false } client ||
            HarnessModule(activePane) is not { Enabled: true, ProgressConnector: true, ProgressSetup: "configured" or "missingHome" } module ||
            (polling && module.ProgressGuide is not { Waiting: true }) ||
            session.Current.DisabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal)) return;
        // The app reads its MCP file when it starts, so the card needs to know
        // whether it runs and since when.
        var (running, started) = await Task.Run(() => AppPresence(module.Launch?.Executables));
        try { await client.SendAsync("refreshHarnessProgressConnection", new { provider = module.Provider, appRunning = running, appStartedAt = started }); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { }
    }

    /// Whether any of the app's executables runs, and when its earliest process
    /// started (seconds since 1970). Reads only process names and start times.
    internal static (bool Running, double? StartedAt) AppPresence(IReadOnlyList<string>? executables)
    {
        if (executables is not { Count: > 0 }) return (false, null);
        bool running = false; DateTime? earliest = null;
        foreach (string name in executables.Select(path => System.IO.Path.GetFileNameWithoutExtension(path.Replace('/', '\\')))
                     .Where(name => name.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            System.Diagnostics.Process[] processes;
            try { processes = System.Diagnostics.Process.GetProcessesByName(name); }
            catch (InvalidOperationException) { continue; }
            foreach (var process in processes)
            {
                using (process)
                {
                    running = true;
                    try { var start = process.StartTime.ToUniversalTime(); if (earliest == null || start < earliest) earliest = start; }
                    catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
                }
            }
        }
        return (running, earliest.HasValue ? (earliest.Value - DateTime.UnixEpoch).TotalSeconds : null);
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
        var guide = closed || !module.Enabled ? null : module.ProgressGuide;
        RefreshHarnessProgressGuide(module.Provider, guide, editable);
        if (harnessProgressPoll != null)
        {
            bool poll = guide is { Waiting: true } && progressOn && !demo;
            if (poll && !harnessProgressPoll.IsEnabled) harnessProgressPoll.Start();
            else if (!poll) harnessProgressPoll.Stop();
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
