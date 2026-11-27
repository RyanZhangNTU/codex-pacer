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

/// A module read by the shared local adapter, laid out like every module page:
/// the header switch, Status (task monitoring, account, usage), Display
/// (progress ring, usage per turn), Usage Settings (the credits in detail) and
/// the folded data folder.
internal sealed partial class SettingsWindow
{
    private StackPanel? harnessSections;
    private Border? harnessOff;
    private CheckBox? harnessEnabled, harnessProgress, harnessTurnCredits;
    private Button? harnessAutomatic;
    private Ellipse? harnessAccountDot;
    private TextBlock? harnessDetection, harnessUsage;
    private Grid? harnessUsageRow;
    // The progress ring's step card, for a module whose app must trust Pacer's tool.
    private Border? harnessProgressChip;
    private TextBlock? harnessProgressChipText, harnessProgressInfo;
    private StackPanel? harnessProgressBody;
    private string harnessProgressKey = "";
    private DispatcherTimer? harnessProgressPoll;
    private TextBlock? harnessAccountState, harnessAccountHelp;
    private StackPanel? harnessCreditsBlock;
    private string harnessCreditsKey = "";
    private Button? harnessAccountSignIn, harnessAccountOptions;
    private TextBlock? harnessQuotaAccount, harnessQuotaUsage;
    private Button? harnessOpenApp, harnessQuotaRefresh;
    private ComboBox? harnessGroup;

    private void ClearHarnessPage()
    {
        harnessSections = null; harnessOff = null;
        harnessEnabled = harnessProgress = harnessTurnCredits = null;
        harnessAutomatic = null;
        harnessAccountDot = null;
        harnessDetection = harnessUsage = null; harnessUsageRow = null;
        harnessProgressPoll?.Stop(); harnessProgressPoll = null;
        harnessProgressChip = null; harnessProgressChipText = harnessProgressInfo = null; harnessProgressBody = null; harnessProgressKey = "";
        harnessAccountState = harnessAccountHelp = null; harnessCreditsBlock = null; harnessCreditsKey = "";
        harnessAccountSignIn = harnessAccountOptions = null;
        harnessQuotaAccount = harnessQuotaUsage = null; harnessOpenApp = harnessQuotaRefresh = null; harnessGroup = null;
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

        // Task monitoring, with Rescan while nothing is found, as every module's first row.
        var rows = new List<UIElement> { ModuleStatusRow(provider + ".monitoring", ui.Text("provider.monitoring")) };
        if (descriptor.ReportsAccountCredits == true)
        {
            rows.Add(BuildHarnessAccountRow(provider, id));
            // The credits available now, while signed in, as on the Mac; the credits in detail wait in Usage Settings.
            harnessUsage = Label("", 12.5); harnessUsage.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            Identify(harnessUsage, id + ".usage", "");
            harnessUsageRow = InfoRow(ui.Text("provider.usage"), harnessUsage, id: id + ".usage"); harnessUsageRow.Visibility = Visibility.Collapsed;
            rows.Add(harnessUsageRow);
            harnessCreditsBlock = new StackPanel(); Identify(harnessCreditsBlock, id + ".credits_block", ui.Text("harness.credits"));
        }
        if (descriptor.QuotaGroups != null)
        {
            StackPanel Actions(TextBlock label, Button button)
            {
                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                label.VerticalAlignment = VerticalAlignment.Center; label.Margin = new Thickness(0, 0, 8, 0);
                actions.Children.Add(label); actions.Children.Add(button); return actions;
            }
            harnessQuotaAccount = Label("", 12.5); harnessQuotaUsage = Label("", 12.5);
            string open = HarnessAccountCard.Fields(ui, "activity.open_app", descriptor.DisplayName ?? provider);
            harnessOpenApp = new Button { Content = open }; Identify(harnessOpenApp, id + ".open", open);
            harnessOpenApp.Click += async (_, _) =>
            {
                if (!demo && !await WindowsConversationApplication.OpenApplicationAsync(provider))
                    ShowIssueText(HarnessAccountCard.Fields(ui, "progress_guide.plugin.open_failed", descriptor.DisplayName ?? provider));
            };
            harnessQuotaRefresh = new Button { Content = ui.Text("common.refresh") };
            Identify(harnessQuotaRefresh, id + ".refresh", ui.Text("common.refresh"));
            harnessQuotaRefresh.Click += async (_, _) =>
            {
                try { await client.SendAsync("retryQuota", new { provider }); }
                catch (Exception error) when (error is System.IO.IOException or OperationCanceledException or InvalidOperationException)
                { ShowIssue("windows.connection.refresh_failed"); }
            };
            rows.Add(InfoRow(ui.Text("provider.account"), Actions(harnessQuotaAccount, harnessOpenApp), id: id + ".account"));
            rows.Add(InfoRow(ui.Text("provider.usage"), Actions(harnessQuotaUsage, harnessQuotaRefresh), id: id + ".usage"));
        }
        harnessSections.Children.Add(SectionTitle(ui.Text("main.section.status")));
        harnessSections.Children.Add(Card(rows.ToArray()));

        var display = new List<UIElement>();
        if (descriptor.QuotaGroups is { } groups)
        {
            var choice = harnessGroup = new ComboBox { SelectedValuePath = "Tag", MinWidth = 120 };
            foreach (var item in groups.Options) choice.Items.Add(new ComboBoxItem { Tag = item.Id, Content = item.Label });
            choice.SelectedValue = groups.Selected; Identify(choice, id + ".group", groups.Title); editors.Add(choice);
            choice.SelectionChanged += async (_, _) =>
            {
                if (synchronizing || busy || activePane != provider || choice.SelectedValue is not string selected ||
                    selected == HarnessModule(provider)?.QuotaGroups?.Selected) return;
                await Change(p => p with { HarnessQuotaGroups = new(p.HarnessQuotaGroups) { [groups.DefaultsKey] = selected } });
            };
            display.Add(InfoRow(groups.Title, choice, id: id + ".quota_group"));
        }
        if (descriptor.HasTaskProgress == true) display.Add(BuildHarnessProgressRow(provider, id, descriptor));
        if (descriptor.ReportsAccountCredits == true || descriptor.ReportsSessionUsage == true)
        {
            var credits = Toggle("provider.turn_usage", "main.info.harness_turn_credits", id + ".turn_credits", out var creditsSwitch);
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
        if (harnessCreditsBlock != null)
        {
            harnessSections.Children.Add(SectionTitle(ui.Text("provider.usage_settings")));
            harnessSections.Children.Add(Card(harnessCreditsBlock));
        }
        if (descriptor.Local == true) harnessSections.Children.Add(Card(ProviderHomeEditor(provider)));
    }

    /// The progress ring switch. A module whose app must trust Pacer's tool also
    /// gets Core's step card under it, until the app has reported progress.
    internal UIElement BuildHarnessProgressRow(string provider, string id, EngineModule descriptor)
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
        var poll = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1.5) };
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
        // A prompt the user opened (restart despite a running task, or restart to
        // point) lasts while its step does.
        if (harnessGuidePrompt is { } prompt && (prompt.Provider != provider || prompt.Stage != guide?.Stage)) harnessGuidePrompt = null;
        string key = System.Text.Json.JsonSerializer.Serialize(new { guide, editable, ui.Language, prompt = harnessGuidePrompt, light = settingsLight });
        if (key == harnessProgressKey) return;
        harnessProgressKey = key;
        foreach (UIElement child in harnessProgressBody.Children) PageAccessibility.Retire(child);
        harnessProgressBody.Children.Clear();
        // A stage with only an action, such as opening an app never opened, still shows its button, as on the Mac.
        bool shown = guide != null && (guide.Steps.Count > 0 || guide.Line != null || guide.Action != null || guide.Picture != null);
        harnessProgressBody.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;

        Button? Action()
        {
            if (guide!.Action is not string action || guide.ActionTitle is not string title) return null;
            // A prompt turns the button into its confirmation.
            if (harnessGuidePrompt is { Kind: "tasks" }) { action = "restartConfirmed"; title = ui.Text("progress_guide.restart.confirm_action"); }
            bool canAct = editable && (!demo || action == "openApp");
            var button = new Button { Content = title, IsEnabled = canAct, Margin = new Thickness(0, 0, 10, 0) };
            if (action != "retry") button.Style = (Style)FindResource("SettingsProminentButton");
            Identify(button, id + ".progress_action", title); editors.Add(button);
            button.Click += async (_, _) =>
            {
                if (!canAct) return;
                button.IsEnabled = false;
                bool done = action switch
                {
                    "openConnectors" => await OpenHarnessConnectorsAsync(provider, guide.Stage == "launch"),
                    "openApp" => await OpenHarnessGuideAppAsync(provider),
                    "restartApp" => await RestartHarnessAppAsync(provider, confirmed: false),
                    "restartConfirmed" => await RestartHarnessAppAsync(provider, confirmed: true),
                    _ => await RetryHarnessProgressAsync(provider)
                };
                if (harnessProgressBody == null) return;
                button.IsEnabled = canAct;
                if (!done && action == "retry") ShowIssue("harness.progress_state.failed");
                else if (!done) ShowIssueText(HarnessAccountCard.Fields(ui, WindowsConversationApplication.CanOpenConnectors(provider)
                    ? "harness.progress_state.open_failed" : "progress_guide.plugin.open_failed",
                    HarnessModule(provider)?.DisplayName is { Length: > 0 and <= 64 } app ? app : PaneTitle(provider)));
            };
            return button;
        }
        string? waitingText = guide!.WaitingText;
        if (waitingText == null && guide.Waiting && HarnessModule(provider)?.Launch?.ConnectorsPath != null)
            waitingText = ui.Text("progress_guide.waiting");
        UIElement ActionRow()
        {
            var row = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            if (harnessGuidePrompt is { } shownPrompt)
            {
                string name = HarnessModule(provider)?.DisplayName ?? provider;
                var note = Label(ui.Text("progress_guide.restart.confirm").Replace("%@", name, StringComparison.Ordinal), 12.5);
                note.TextWrapping = TextWrapping.Wrap; note.Margin = new Thickness(0, 0, 0, 6); note.Width = 420;
                note.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
                Identify(note, id + ".progress_prompt", note.Text); row.Children.Add(note);
            }
            if (Action() is { } button) row.Children.Add(button);
            if (waitingText != null)
            {
                var waiting = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var glyph = new IconGlyph { Symbol = "clock", Width = 13, Height = 13, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
                glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
                var text = Label(waitingText, 12); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                text.VerticalAlignment = VerticalAlignment.Center;
                waiting.Children.Add(glyph); waiting.Children.Add(text);
                Identify(waiting, id + ".progress_waiting", text.Text);
                row.Children.Add(waiting);
            }
            return row;
        }

        void AddPicture(StackPanel parent)
        {
            if (ProgressGuidePicture.Draw(guide.Picture, guide.ApprovalCard, provider, ui, settingsLight) is not { } picture) return;
            picture.Margin = new Thickness(0, 8, 0, 0);
            if (picture.HorizontalAlignment != HorizontalAlignment.Stretch) { parent.Children.Add(picture); return; }
            // As on the Mac, a stretching picture fills the width up to its maximum, from the left.
            var holder = new Grid();
            holder.ColumnDefinitions.Add(new ColumnDefinition { MaxWidth = picture.MaxWidth });
            picture.MaxWidth = double.PositiveInfinity;
            holder.Children.Add(picture);
            parent.Children.Add(holder);
        }

        if (guide.Steps.Count == 0)
        {
            var problem = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
            if (guide.Line is string message)
            {
                var line = Label(message, 12.5); line.TextWrapping = TextWrapping.Wrap;
                Identify(line, id + ".progress_line", message); problem.Children.Add(line);
            }
            AddPicture(problem);
            if (guide.Action != null || waitingText != null) problem.Children.Add(ActionRow());
            harnessProgressBody.Children.Add(problem);
            return;
        }
        for (int index = 0; index < guide.Steps.Count; index++)
        {
            var step = guide.Steps[index];
            var line = new Grid { Margin = new Thickness(0, index == 0 ? 0 : 4, 0, index == guide.Steps.Count - 1 ? 12 : 4) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            line.ColumnDefinitions.Add(new ColumnDefinition());
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
            // Only the current step shows where to click, as one large picture.
            if (step.State == "current")
            {
                if (guide.Example is string example)
                    body.Children.Add(new ProgressGuideExample(example, ui) { Margin = new Thickness(0, 4, 0, 0) });
                if (step.Detail is string detail)
                {
                    var text = Label(detail, 12.5);
                    text.Margin = new Thickness(0, 4, 0, 0); text.TextWrapping = TextWrapping.Wrap;
                    text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                    Identify(text, id + ".progress_detail", detail); body.Children.Add(text);
                }
                AddPicture(body);
                if (guide.Action != null || waitingText != null) body.Children.Add(ActionRow());
            }
            line.Children.Add(body);
            Identify(line, id + ".progress_step" + index, step.Title);
            AutomationProperties.SetItemStatus(line, ui.Text("progress_guide.state." + step.State));
            harnessProgressBody.Children.Add(line);
        }
    }

    /// A credits dial on this page draws with the page's theme brushes and the brand's shade for it.
    private QuotaDialInk SettingsDialInk(string provider)
    {
        Brush Resource(string key, Brush fallback) => TryFindResource(key) as Brush ?? fallback;
        return new QuotaDialInk(Resource("SettingsPrimary", PacerPalette.Primary), Resource("SettingsSecondary", PacerPalette.Secondary),
            Resource("SettingsWarning", PacerPalette.Attention), Resource("SettingsSeparator", PacerPalette.Hairline),
            settingsLight ? Brushes.White : Brushes.Black, PacerPalette.BrandShade(provider, settingsLight));
    }

    // Which modules' connectors the user opened from the card, and when, for
    // the guide's open and custom steps.
    private static readonly Dictionary<string, DateTime> openedHarnessConnectors = new(StringComparer.Ordinal);
    // Modules whose app Pacer is restarting: a check in between sees it closed.
    private static readonly HashSet<string> restartingHarnessApps = new(StringComparer.Ordinal);
    internal static bool RestartingHarness(string provider) => restartingHarnessApps.Contains(provider);

    // A confirmation the card shows in place of its action.
    private sealed record HarnessGuidePrompt(string Provider, string Stage, string Kind);
    private HarnessGuidePrompt? harnessGuidePrompt;

    private void ShowGuidePrompt(string provider, string kind)
    {
        if (HarnessModule(provider)?.ProgressGuide is not { } guide) return;
        harnessGuidePrompt = new(provider, guide.Stage, kind);
        RefreshHarnessProgressGuide(provider, guide, true);
    }

    /// Opens the connectors. A closed app starts there, and the floating guide
    /// then shows the next click beside it.
    private async Task<bool> OpenHarnessConnectorsAsync(string provider, bool launch = false)
    {
        if (!await WindowsConversationApplication.OpenProgressConnectorsAsync(provider)) return false;
        openedHarnessConnectors[provider] = DateTime.UtcNow;
        OpenGuideFloat(provider);
        _ = AppWindows.BringForwardAsync(HarnessModule(provider)?.Launch?.Executables);
        await RefreshHarnessProgressConnectionAsync(polling: true, provider);
        return true;
    }

    private async Task<bool> OpenHarnessGuideAppAsync(string provider)
    {
        OpenGuideFloat(provider);
        if (demo || await WindowsConversationApplication.OpenApplicationAsync(provider)) return true;
        CloseGuideFloat(provider);
        return false;
    }

    /// One click for the reopen step: Pacer closes the app and opens it at its
    /// connectors, then floats the next click beside it. A running task asks first.
    private async Task<bool> RestartHarnessAppAsync(string provider, bool confirmed)
    {
        if (HarnessModule(provider) is not { Launch.Executables: { Count: > 0 } executables } module) return false;
        bool busy = engine?.LatestSnapshot?.Tasks.Any(task => task.Provider == provider && task.Phase is not ("completed" or "interrupted")) == true;
        if (busy && !confirmed) { ShowGuidePrompt(provider, "tasks"); return true; }
        harnessGuidePrompt = null;
        if (!restartingHarnessApps.Add(provider)) return true;
        // The guide says Pacer is restarting the app right away; it takes seconds.
        OpenGuideFloat(provider);
        bool reopenFloat = false;
        try
        {
            var result = await WindowsConversationApplication.RestartForGuideAsync(provider, executables);
            if (result == WindowsConversationApplication.RestartResult.StillRunning)
            {
                reopenFloat = HarnessGuideFloat.Current?.Provider == provider;
                CloseGuideFloat(provider);
                issue.Text = ui.Text("progress_guide.restart.failed").Replace("%@", module.DisplayName ?? provider, StringComparison.Ordinal);
                issue.Visibility = Visibility.Visible;
                // Once the user quits it, Pacer opens it again, as the hint says.
                if (!await WindowsConversationApplication.WaitForExitAsync(provider, executables, TimeSpan.FromMinutes(3))
                    || !await WindowsConversationApplication.ReopenForGuideAsync(provider)) return true;
                issue.Visibility = Visibility.Collapsed;
            }
            else if (result != WindowsConversationApplication.RestartResult.Restarted) { CloseGuideFloat(provider); return false; }
            if (module.Launch.ConnectorsPath != null) openedHarnessConnectors[provider] = DateTime.UtcNow;
        }
        finally { restartingHarnessApps.Remove(provider); }
        if (reopenFloat) OpenGuideFloat(provider);
        else HarnessGuideFloat.Follow();
        if (module.Launch.ConnectorsPath != null) _ = AppWindows.BringForwardAsync(executables);
        await RefreshHarnessProgressConnectionAsync(polling: true, provider);
        return true;
    }

    /// Opens the floating guide for the app the card just opened, or keeps the
    /// one already open for it. It follows the app after Settings closes.
    private void OpenGuideFloat(string provider)
    {
        if (engine is not { } client || HarnessModule(provider) is not { } module) return;
        var area = System.Windows.Forms.Screen.FromHandle(new System.Windows.Interop.WindowInteropHelper(this).Handle).WorkingArea;
        HarnessGuideFloat.Open(module, client, session, ui, Resources, settingsLight, area);
    }

    private static void CloseGuideFloat(string provider)
    {
        if (HarnessGuideFloat.Current is { } shown && shown.Provider == provider) shown.Close();
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
        return InfoRow(ui.Text("provider.account"), trailing, detail: harnessAccountHelp, id: id + ".account");
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
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(ui.Text("harness.account.switch"), "switch_account", () => _ = RunHarnessAccountAsync(account.SwitchAsync)));
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
    /// how each kind of credit behaves.
    private void RefreshHarnessCredits(string provider, HarnessAccountConnection? account)
    {
        if (harnessCreditsBlock == null) return;
        var credits = engine?.LatestSnapshot?.AccountCredits?.FirstOrDefault(value => value.Provider == provider);
        var presentation = account?.Reading == null ? null : credits?.Presentation;
        if (harnessUsage != null && harnessUsageRow != null)
        {
            // Signed out, the account row asks to sign in and the usage row waits for the first reading.
            var total = presentation?.Lines.LastOrDefault();
            harnessUsageRow.Visibility = total == null ? Visibility.Collapsed : Visibility.Visible;
            harnessUsage.Text = total?.Value ?? ""; AutomationProperties.SetName(harnessUsage, harnessUsage.Text);
            harnessUsage.SetResourceReference(TextBlock.ForegroundProperty, total?.Warns == true ? "SettingsWarning" : "SettingsSecondary");
        }
        string key = System.Text.Json.JsonSerializer.Serialize(new { presentation, stale = credits?.Stale, state = account?.State, busy = account?.Busy, ui.Language, light = settingsLight });
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
            return;
        }
        var top = new Grid { Margin = new Thickness(14, 12, 14, 12) };
        top.ColumnDefinitions.Add(new() { Width = new GridLength(104) }); top.ColumnDefinitions.Add(new() { Width = new GridLength(20) }); top.ColumnDefinitions.Add(new());
        // The page's own ink, not the island's: the island's light text vanished on a light page.
        var dial = new QuotaDial(provider, null, null, dialSize: 104, credits: presentation.Dial, creditsText: ui, creditsStale: credits?.Stale == true,
            ink: SettingsDialInk(provider)) { Width = 104, Height = 104, VerticalAlignment = VerticalAlignment.Center };
        Identify(dial, id + ".credits_dial", presentation.Dial.AccessibilityLabel);
        top.Children.Add(dial);
        // As the Overview card's: the lines run to the card's edge, so their values end where the breakdown's dates do.
        var lines = HarnessAccountCard.Lines(presentation, provider, island: false, id + ".credits_line", PacerPalette.BrandShade(provider, settingsLight));
        lines.VerticalAlignment = VerticalAlignment.Center;
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
    }

    /// Checks the app's trust again: when Settings comes forward, and every few
    /// seconds while the step card or the floating guide waits on the app.
    /// <param name="provider">The module to check; the page's own by default.</param>
    private async Task RefreshHarnessProgressConnectionAsync(bool polling = false, string? provider = null)
    {
        if (demo || (!polling && !IsActive) || engine is not { } client) return;
        await CheckHarnessAppAsync(client, session, provider ?? activePane, polling);
    }

    /// Tells the engine whether the module's app runs, since when, and when the
    /// user opened its connectors from the card. Shared with the floating
    /// guide, which keeps checking after Settings closes.
    /// <param name="polling">Only while the card waits on the app.</param>
    internal static async Task CheckHarnessAppAsync(EngineClient client, PreferencesSession session, string provider, bool polling)
    {
        if (client.IsConnectionClosed || client.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == provider)
                is not { ProgressConnector: true } module) return;
        if (module.ProgressSetup != "removalPending" &&
            (!module.Enabled || module.ProgressSetup is not ("configured" or "missingHome") ||
             (polling && module.ProgressGuide is not { Waiting: true }) ||
             session.Current.DisabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal))) return;
        // The app reads its MCP file when it starts, so the card needs to know
        // whether it runs and since when. The engine reads which page it shows
        // from the app's log.
        string checkedProvider = module.Provider;
        if (restartingHarnessApps.Contains(checkedProvider)) return;
        // The card and the floating guide both poll; one check runs at a time.
        if (!checkingHarnessApps.Add(checkedProvider)) return;
        try { await CheckHarnessAppOnceAsync(client, checkedProvider, module); }
        finally { checkingHarnessApps.Remove(checkedProvider); }
    }
    private static readonly HashSet<string> checkingHarnessApps = new(StringComparer.Ordinal);
    private static async Task CheckHarnessAppOnceAsync(EngineClient client, string checkedProvider, EngineModule module)
    {
        var checkedAt = DateTime.UtcNow;
        var (running, started) = await Task.Run(() => AppPresence(module.Launch?.Executables, provider: checkedProvider));
        // A check that ran while Pacer restarted the app, or that saw it closed
        // while Pacer opened it, is stale: it would send the card back a step.
        if (restartingHarnessApps.Contains(checkedProvider)
            || !running && openedHarnessConnectors.TryGetValue(checkedProvider, out var openedAt) && openedAt >= checkedAt) return;
        if (!running) openedHarnessConnectors.Remove(checkedProvider);
        // An app that started again since shows its home page, and its own
        // listing as it starts must not count as the user's click.
        else if (started is double since && openedHarnessConnectors.TryGetValue(checkedProvider, out var opened)
                 && since > (opened - DateTime.UnixEpoch).TotalSeconds) openedHarnessConnectors.Remove(checkedProvider);
        double? openedConnectorsAt = openedHarnessConnectors.TryGetValue(checkedProvider, out var connectorsShown)
            ? (connectorsShown - DateTime.UnixEpoch).TotalSeconds : null;
        try
        {
            await client.SendAsync("refreshHarnessProgressConnection", new { provider = checkedProvider, appRunning = running, appStartedAt = started,
                openedConnectorsAt });
        }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { }
    }

    /// Whether any of the app's executables runs, and when its earliest process
    /// started (seconds since 1970).
    internal static (bool Running, double? StartedAt) AppPresence(IReadOnlyList<string>? executables, string? provider = null)
    {
        if (executables is not { Count: > 0 }) return (false, null);
        string? verified = provider == "antigravity" ? WindowsAntigravityInstallation.Resolve() : null;
        if (provider == "antigravity" && verified == null) return (false, null);
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
                    if (verified != null && !WindowsConversationApplication.Matches(process, verified)) continue;
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
        RefreshHarnessAccount(editable && module.Enabled);
        if (harnessGroup != null && module.QuotaGroups is { } groups)
        {
            var snapshot = engine?.LatestSnapshot;
            var reading = snapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == module.Provider);
            var full = snapshot?.GroupedQuota?.FirstOrDefault(value => value.Provider == module.Provider);
            harnessQuotaAccount!.Text = full?.AccountScope != null ? ui.Text("harness.account.signed_in") : "";
            harnessQuotaUsage!.Text = reading?.GroupWeeks?.FirstOrDefault(value => value.Id == groups.Selected)?.Remaining ?? "—";
            harnessOpenApp!.IsEnabled = editable && !demo && module.HasApplication == true;
            harnessQuotaRefresh!.IsEnabled = editable && module.Enabled && reading?.History?.Refreshing != true;
            harnessGroup.IsEnabled = editable; harnessGroup.SelectedValue = groups.Selected;
        }
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
            bool poll = guide is { Waiting: true } && (progressOn || guide.Stage == "removalPending") && !demo;
            if (poll && !harnessProgressPoll.IsEnabled) harnessProgressPoll.Start();
            else if (!poll) harnessProgressPoll.Stop();
        }
        RefreshModuleStatusRow(module.Provider + ".monitoring", module.Monitoring);
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
        // The Mac's order: reading before the first credits, a failed read in
        // amber with its sentence under the row, then signed in with the plan.
        bool signedIn = account?.Reading != null, busyReading = account?.Busy == true && !signedIn, failed = account?.State == "unavailable";
        string state = ui.Text(busyReading ? "harness.account.reading" : signedIn ? "harness.account.signed_in" : "harness.account.signed_out")
            + (!busyReading && account?.Reading?.Plan is { Length: > 0 } plan ? " · " + plan : "");
        SetStatus(harnessAccountDot, harnessAccountState, state, busyReading ? "neutral" : failed || !signedIn ? "attention" : "positive");
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
