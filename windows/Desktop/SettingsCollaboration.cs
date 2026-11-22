using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// Settings → Collaboration, a page of its own as on the Mac: Codex for Claude's
/// workbench. A header with the switch and a status strip; until the first run,
/// how it works and three steps to start; then what runs now, the statistics,
/// recent runs, the defaults the runner applies when Claude leaves them out,
/// display and alerts, and checks. Explanations wait behind ⓘ.
internal sealed partial class SettingsWindow
{
    private CheckBox? delegationEnabled;
    private WrapPanel? delegationStrip;
    private StackPanel? delegationLive, delegationChecks, delegationRunning;
    private FrameworkElement? delegationEditors;
    private string? delegationSignature, delegationRunningSignature;
    private bool delegationChecked;
    private ComboBox? delegationModel, delegationDisplay, delegationEffort, delegationFast, delegationAccess, delegationTimeout,
        delegationConcurrency, delegationInitiative, delegationLongRun;
    private CheckBox? delegationFailureAlerts;

    private void ClearCollaboration()
    {
        delegationEnabled = null; delegationStrip = null; delegationLive = delegationChecks = delegationRunning = null; delegationEditors = null;
        delegationSignature = delegationRunningSignature = null; delegationModel = delegationDisplay = delegationEffort = delegationFast = delegationAccess = null;
        delegationTimeout = delegationConcurrency = delegationInitiative = delegationLongRun = null; delegationFailureAlerts = null;
    }

    private void BuildCollaboration()
    {
        // Header: Claude → Codex, the title with its ⓘ and the switch, then the status strip.
        var main = Toggle("collaboration.codex_for_claude", "collaboration.info.codex_for_claude", "settings.collaboration.enabled", out var enabled);
        delegationEnabled = enabled; editors.Add(enabled);
        BindToggle(enabled, (p, value) => p with { CodexDelegation = value });
        var pair = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 12, 0, 0) };
        pair.Children.Add(GuideArt.Tile(GuideArt.ProviderSymbol("claude"), Color.FromRgb(201, 103, 58), 26));
        var arrow = Label("→", 12); arrow.Margin = new Thickness(6, 0, 6, 0); arrow.VerticalAlignment = VerticalAlignment.Center;
        arrow.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); pair.Children.Add(arrow);
        pair.Children.Add(GuideArt.Tile(GuideArt.ProviderSymbol("codex"), Color.FromRgb(17, 128, 109), 26));
        delegationStrip = new WrapPanel { Margin = new Thickness(14, 0, 14, 12) };
        var header = new StackPanel(); header.Children.Add(pair); header.Children.Add(main); header.Children.Add(delegationStrip);
        form.Children.Add(Card(header));

        delegationLive = new StackPanel(); form.Children.Add(delegationLive);
        delegationEditors = BuildDelegationEditors(); form.Children.Add(delegationEditors);
        delegationChecks = new StackPanel(); form.Children.Add(delegationChecks);
        RefreshCollaboration();
        // The page asks Codex for its version, sign-in and models once each time it opens.
        if (!delegationChecked && engine != null) { delegationChecked = true; _ = SendDelegation("checkCodexDelegation"); }
    }

    private FrameworkElement BuildDelegationEditors()
    {
        var panel = new StackPanel();
        string follow = ui.Text("collaboration.follow");
        delegationModel = Choices("settings.collaboration.model", [("", follow)], (p, value) => p with { CodexDelegationModel = value });
        delegationEffort = Choices("settings.collaboration.effort",
            DesktopPreferences.DelegationEfforts.Select(value => (value, value.Length == 0 ? follow : ui.Text("collaboration.effort." + value))).ToArray(),
            (p, value) => p with { CodexDelegationEffort = value });
        delegationFast = Choices("settings.collaboration.fast", [("", follow), ("on", ui.Text("collaboration.fast.on")), ("off", ui.Text("collaboration.fast.off"))],
            (p, value) => p with { CodexDelegationFast = value });
        panel.Children.Add(SectionTitle(ui.Text("collaboration.section.how_codex_runs")));
        panel.Children.Add(Card(InfoRow(ui.Text("collaboration.model"), delegationModel, ui.Text("collaboration.info.defaults"), id: "settings.collaboration.model_row"),
            InfoRow(ui.Text("collaboration.effort"), delegationEffort), InfoRow(ui.Text("collaboration.fast"), delegationFast)));

        delegationAccess = Choices("settings.collaboration.access", [("read", ui.Text("collaboration.access.read_only")), ("write", ui.Text("collaboration.access.write"))],
            (p, value) => p with { CodexDelegationWrite = value == "write" });
        string minutes = ui.Text("collaboration.unit.minutes");
        delegationTimeout = Choices("settings.collaboration.timeout",
            DesktopPreferences.DelegationTimeouts.Select(value => (value.ToString(), value + " " + minutes)).ToArray(),
            (p, value) => p with { CodexDelegationTimeout = int.Parse(value) });
        delegationConcurrency = Choices("settings.collaboration.concurrency",
            DesktopPreferences.DelegationConcurrency.Select(value => (value.ToString(), value.ToString())).ToArray(),
            (p, value) => p with { CodexDelegationConcurrency = int.Parse(value) });
        delegationInitiative = Choices("settings.collaboration.initiative",
            DesktopPreferences.DelegationInitiatives.Select(value => (value, ui.Text("collaboration.initiative." + value))).ToArray(),
            (p, value) => p with { CodexDelegationInitiative = value });
        panel.Children.Add(SectionTitle(ui.Text("collaboration.section.limits")));
        panel.Children.Add(Card(InfoRow(ui.Text("collaboration.access"), delegationAccess, ui.Text("collaboration.info.access"), id: "settings.collaboration.access_row"),
            InfoRow(ui.Text("collaboration.timeout"), delegationTimeout), InfoRow(ui.Text("collaboration.concurrency"), delegationConcurrency),
            InfoRow(ui.Text("collaboration.initiative"), delegationInitiative, ui.Text("collaboration.info.initiative"), id: "settings.collaboration.initiative_row")));

        delegationDisplay = Choices("settings.collaboration.display", [("rows", ui.Text("collaboration.display.rows")), ("count", ui.Text("collaboration.display.count"))],
            (p, value) => p with { CodexDelegationRows = value == "rows" });
        var failures = Toggle("collaboration.failure_alerts", null, "settings.collaboration.failure_alerts", out var failureSwitch);
        delegationFailureAlerts = failureSwitch; editors.Add(failureSwitch);
        BindToggle(failureSwitch, (p, value) => p with { CodexDelegationFailureAlerts = value });
        delegationLongRun = Choices("settings.collaboration.long_run",
            DesktopPreferences.DelegationLongRuns.Select(value => (value.ToString(), value == 0 ? ui.Text("collaboration.long_run.off") : value + " " + minutes)).ToArray(),
            (p, value) => p with { CodexDelegationLongRun = int.Parse(value) });
        panel.Children.Add(SectionTitle(ui.Text("collaboration.section.display_alerts")));
        panel.Children.Add(Card(InfoRow(ui.Text("collaboration.display"), delegationDisplay), failures,
            InfoRow(ui.Text("collaboration.long_run"), delegationLongRun)));
        return panel;
    }

    private ComboBox Choices(string id, (string Value, string Label)[] choices, Func<DesktopPreferences, string, DesktopPreferences> write)
    {
        var box = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 150, MaxWidth = 260, SelectedValuePath = "Tag" };
        foreach (var (value, label) in choices) box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        Identify(box, id, "");
        box.SelectionChanged += async (_, _) => { if (!synchronizing && box.SelectedValue is string value) await Change(p => write(p, value)); };
        editors.Add(box);
        return box;
    }

    private async System.Threading.Tasks.Task SendDelegation(string method, object? parameters = null)
    {
        if (engine == null || sourceClosed) return;
        try { await engine.SendAsync(method, parameters); }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException) { }
    }

    private void RefreshCollaboration()
    {
        if (delegationEnabled == null || engine == null) return;
        var snapshot = engine.LatestSnapshot;
        var status = snapshot?.CodexDelegation;
        var current = session.Current;
        bool claude = snapshot?.Modules?.FirstOrDefault(module => module.Provider == "claude")?.Enabled == true;
        bool connected = !providerConnectionClosed && !engine.IsConnectionClosed && snapshot != null;
        bool editable = connected && claude && !busy && !session.RequiresRestart;
        delegationEnabled.IsChecked = current.CodexDelegation;
        delegationEnabled.IsEnabled = editable;
        RefreshDelegationEditors(current, status, editable);
        delegationEditors!.Visibility = current.CodexDelegation ? Visibility.Visible : Visibility.Collapsed;
        // The live parts change with every snapshot; rebuild them only when what they show changed.
        // Runs going now redraw every second, so they have their own card and signature.
        var running = current.CodexDelegation && status?.Running is { Count: > 0 } list ? list : null;
        string runningSignature = JsonSerializer.Serialize(new { running, status?.Limit, ui.Language });
        string signature = JsonSerializer.Serialize(new { status = status == null ? null : status with { Running = null }, runningCount = running?.Count, current.CodexDelegation,
            current.CodexDelegationStatsDays, current.HideProjects, editable, ui.Language });
        if (signature != delegationSignature)
        {
            delegationSignature = signature;
            BuildDelegationLive(status, current, editable);
            delegationRunningSignature = null;
        }
        if (delegationRunning == null || runningSignature == delegationRunningSignature) return;
        delegationRunningSignature = runningSignature;
        delegationRunning.Children.Clear();
        if (running != null) delegationRunning.Children.Add(RunningCard(running, status!.Limit));
    }

    private void BuildDelegationLive(CodexDelegationStatus? status, DesktopPreferences current, bool editable)
    {
        BuildDelegationStrip(status, current);
        delegationLive!.Children.Clear(); delegationChecks!.Children.Clear(); delegationRunning = null;
        if (!current.CodexDelegation || status is not { FirstRunSeen: true }) { delegationLive.Children.Add(HowItWorks()); delegationLive.Children.Add(StartSteps(status, current, editable)); }
        if (!current.CodexDelegation) return;
        if (status is { FirstRunSeen: true } && status.RunsTotal < 3) delegationLive.Children.Add(TryIt());
        delegationRunning = new StackPanel(); delegationLive.Children.Add(delegationRunning);
        if (status is { FirstRunSeen: true })
        {
            var stats = current.CodexDelegationStatsDays == 7 ? status.Stats7 : status.Stats30;
            if (stats != null) delegationLive.Children.Add(StatisticsCard(stats, status.QuotaText, current.CodexDelegationStatsDays));
            if (stats != null) delegationLive.Children.Add(RecentCard(stats));
            var how = new Expander { Header = ui.Text("collaboration.how.title"), Content = HowItWorks(), Margin = new Thickness(0, 0, 0, 16) };
            Identify(how, "settings.collaboration.how", ui.Text("collaboration.how.title")); delegationLive.Children.Add(how);
        }
        delegationChecks.Children.Add(ChecksCard(status, editable));
    }

    private void RefreshDelegationEditors(DesktopPreferences current, CodexDelegationStatus? status, bool editable)
    {
        // The model list comes from Codex's catalog; a saved model it does not list stays choosable.
        string follow = ui.Text("collaboration.follow");
        string defaultName = status?.DefaultModel is { Length: > 0 } slug ? status.Models?.FirstOrDefault(m => m.Slug == slug)?.Name ?? slug : "";
        var choices = new[] { ("", defaultName.Length == 0 ? follow : follow + " (" + defaultName + ")") }
            .Concat((status?.Models ?? []).Select(model => (model.Slug, model.Name)))
            .Concat(current.CodexDelegationModel.Length > 0 && status?.Models?.Any(m => m.Slug == current.CodexDelegationModel) != true
                ? new[] { (current.CodexDelegationModel, current.CodexDelegationModel) } : []).ToArray();
        var existing = delegationModel!.Items.OfType<ComboBoxItem>().Select(item => ((string)item.Tag, (string)item.Content)).ToArray();
        if (!existing.SequenceEqual(choices))
        {
            delegationModel.Items.Clear();
            foreach (var (value, label) in choices) delegationModel.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        }
        delegationModel.SelectedValue = current.CodexDelegationModel;
        delegationDisplay!.SelectedValue = current.CodexDelegationRows ? "rows" : "count";
        delegationEffort!.SelectedValue = current.CodexDelegationEffort;
        delegationFast!.SelectedValue = current.CodexDelegationFast;
        delegationAccess!.SelectedValue = current.CodexDelegationWrite ? "write" : "read";
        delegationTimeout!.SelectedValue = current.CodexDelegationTimeout.ToString();
        delegationConcurrency!.SelectedValue = current.CodexDelegationConcurrency.ToString();
        delegationInitiative!.SelectedValue = current.CodexDelegationInitiative;
        delegationLongRun!.SelectedValue = current.CodexDelegationLongRun.ToString();
        delegationFailureAlerts!.IsChecked = current.CodexDelegationFailureAlerts;
        foreach (var editor in new Control[] { delegationModel, delegationDisplay, delegationEffort, delegationFast, delegationAccess, delegationTimeout,
                     delegationConcurrency, delegationInitiative, delegationLongRun, delegationFailureAlerts })
            editor.IsEnabled = editable;
    }

    // ---------------------------------------------------------------- status strip

    private void BuildDelegationStrip(CodexDelegationStatus? status, DesktopPreferences current)
    {
        delegationStrip!.Children.Clear();
        if (!current.CodexDelegation) { delegationStrip.Children.Add(Pill(ui.Text("collaboration.status.off"), null)); return; }
        bool ready = status is { CodexFound: true, SkillInstalled: true } && status.Login != "missing";
        delegationStrip.Children.Add(Pill(ui.Text(ready ? "collaboration.status.ready" : "collaboration.status.attention"), ready ? "good" : "warn"));
        if (status?.CodexFound == true)
            delegationStrip.Children.Add(Pill("Codex" + (status.Version is { } version ? " " + version : "")
                + (status.Login is "ok" ? " · " + ui.Text("collaboration.status.signed_in") : status.Login is "missing" ? " · " + ui.Text("collaboration.status.signed_out") : ""),
                status.Login is "missing" ? "warn" : null));
        if (status?.SkillInstalled == true) delegationStrip.Children.Add(Pill(ui.Text("collaboration.status.skill_ready"), null));
        if (status?.Running is { Count: > 0 } running) delegationStrip.Children.Add(Pill(ui.Text("collaboration.status.running") + " " + running.Count, "codex"));
    }

    private static string? ToneKey(string? tone) => tone switch { "good" => "SettingsSuccessText", "warn" => "SettingsWarning", _ => null };
    /// Done in Codex's color, stopped in the secondary ink, failed in the error ink.
    private static void Paint(Shape shape, string result)
    {
        if (result == "ok") shape.Fill = PacerPalette.Provider("codex");
        else shape.SetResourceReference(Shape.FillProperty, result == "failed" ? "SettingsErrorText" : "SettingsSecondary");
    }
    private Border Pill(string text, string? tone)
    {
        var dot = new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center,
            Fill = tone == "codex" ? PacerPalette.Provider("codex") : Brushes.Transparent, Visibility = tone == null ? Visibility.Collapsed : Visibility.Visible };
        if (ToneKey(tone) is { } key) dot.SetResourceReference(Shape.FillProperty, key);
        var label = Label(text, 12); label.VerticalAlignment = VerticalAlignment.Center;
        var content = new StackPanel { Orientation = Orientation.Horizontal }; content.Children.Add(dot); content.Children.Add(label);
        var pill = new Border { Child = content, CornerRadius = new CornerRadius(10), Padding = new Thickness(9, 2, 10, 3), Margin = new Thickness(0, 6, 6, 0) };
        pill.SetResourceReference(Border.BackgroundProperty, "SettingsSearchFill");
        AutomationProperties.SetName(pill, text);
        return pill;
    }

    // ---------------------------------------------------------------- how it works and getting started

    private Border HowItWorks()
    {
        var steps = new System.Windows.Controls.Primitives.UniformGrid { Columns = 5, Margin = new Thickness(10, 14, 10, 6) };
        (string Symbol, Color Tint, string Key)[] nodes = [("text.bubble", Color.FromRgb(91, 102, 112), "you"), (GuideArt.ProviderSymbol("claude"), Color.FromRgb(201, 103, 58), "brief"),
            (GuideArt.ProviderSymbol("codex"), Color.FromRgb(17, 128, 109), "run"), ("checkmark.circle", Color.FromRgb(201, 103, 58), "check"),
            ("sparkle", Color.FromRgb(138, 109, 29), "clean")];
        foreach (var node in nodes)
        {
            var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(4, 0, 4, 0) };
            var tile = GuideArt.Tile(node.Symbol, node.Tint, 30); tile.HorizontalAlignment = HorizontalAlignment.Center; column.Children.Add(tile);
            var title = Label(ui.Text("collaboration.how." + node.Key), 12, FontWeights.SemiBold);
            title.HorizontalAlignment = HorizontalAlignment.Center; title.TextAlignment = TextAlignment.Center; title.Margin = new Thickness(0, 6, 0, 0); column.Children.Add(title);
            var detail = Detail(ui.Text("collaboration.how." + node.Key + "_detail")); detail.FontSize = 11; detail.TextAlignment = TextAlignment.Center;
            detail.TextWrapping = TextWrapping.Wrap; detail.HorizontalAlignment = HorizontalAlignment.Center; column.Children.Add(detail);
            steps.Children.Add(column);
        }
        var rules = new WrapPanel { Margin = new Thickness(14, 2, 14, 12) };
        foreach (var key in new[] { "brief", "read_only", "quota", "writer" }) rules.Children.Add(Pill(ui.Text("collaboration.rule." + key), null));
        var content = new StackPanel(); content.Children.Add(steps); content.Children.Add(rules);
        Identify(content, "settings.collaboration.how_steps", ui.Text("collaboration.how.title"));
        return Card(content);
    }

    private FrameworkElement StartSteps(CodexDelegationStatus? status, DesktopPreferences current, bool editable)
    {
        var panel = new StackPanel();
        panel.Children.Add(SectionTitle(ui.Text("collaboration.start.title")));
        bool found = status?.CodexFound != false && status?.Login != "missing";
        string findDetail = status?.CodexFound == false ? ui.Text("collaboration.start.find_missing")
            : "Codex" + (status?.Version is { } version ? " " + version : "")
              + (status?.Login == "ok" ? " · " + ui.Text("collaboration.status.signed_in") : status?.Login == "missing" ? " · " + ui.Text("collaboration.status.signed_out") : "");
        Button? openCodex = status?.Login == "missing" ? ActionButton(ui.Text("collaboration.check.open_codex"), "settings.collaboration.start.open_codex", OpenCodexApplication) : null;
        var turnOn = ActionButton(ui.Text("collaboration.start.open"), "settings.collaboration.start.turn_on",
            async () => await Change(p => p with { CodexDelegation = true }));
        turnOn.IsEnabled = editable && !current.CodexDelegation;
        string phrase = ui.Text("collaboration.try.review");
        panel.Children.Add(Card(
            Step(1, found && status != null, ui.Text("collaboration.start.find"), findDetail, openCodex),
            Step(2, current.CodexDelegation && status?.SkillInstalled == true, ui.Text("collaboration.start.turn_on"), ui.Text("collaboration.start.turn_on_detail"),
                current.CodexDelegation ? null : turnOn),
            Step(3, status?.FirstRunSeen == true, ui.Text("collaboration.start.try"), "“" + phrase + "”", CopyButton(phrase, "settings.collaboration.start.copy"))));
        return panel;
    }

    private Grid Step(int number, bool done, string title, string detail, UIElement? action)
    {
        var row = new Grid { Margin = new Thickness(14, 9, 14, 9) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(32) }); row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var badge = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), VerticalAlignment = VerticalAlignment.Center,
            Background = done ? PacerPalette.Provider("codex") : Brushes.Transparent, BorderThickness = new Thickness(done ? 0 : 1.5) };
        badge.SetResourceReference(Border.BorderBrushProperty, "SettingsSecondary");
        var mark = Label(done ? "✓" : number.ToString(), 11, FontWeights.Bold); mark.HorizontalAlignment = HorizontalAlignment.Center; mark.VerticalAlignment = VerticalAlignment.Center;
        if (done) mark.Foreground = Brushes.White; badge.Child = mark; row.Children.Add(badge);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Label(title, 13, FontWeights.SemiBold));
        var line = Detail(detail); line.TextWrapping = TextWrapping.Wrap; text.Children.Add(line);
        Grid.SetColumn(text, 1); row.Children.Add(text);
        if (action is FrameworkElement end) { end.VerticalAlignment = VerticalAlignment.Center; end.Margin = new Thickness(10, 0, 0, 0); Grid.SetColumn(end, 2); row.Children.Add(end); }
        AutomationProperties.SetName(row, (done ? "✓ " : number + ". ") + title + ", " + detail);
        return row;
    }

    private Button ActionButton(string title, string id, Action action)
    {
        var button = new Button { Content = title, VerticalAlignment = VerticalAlignment.Center };
        Identify(button, id, title); button.Click += (_, _) => action();
        return button;
    }

    private Button CopyButton(string text, string id)
    {
        var button = new Button { Content = ui.Text("collaboration.copy"), Style = (Style)FindResource("SettingsLink"), VerticalAlignment = VerticalAlignment.Center };
        Identify(button, id, ui.Text("collaboration.copy") + " " + text);
        button.Click += (_, _) =>
        {
            try { Clipboard.SetText(text); button.Content = ui.Text("collaboration.copied"); }
            catch (Exception error) when (error is COMException or ExternalException) { ShowIssue("windows.pages.open_failed"); }
        };
        return button;
    }

    private FrameworkElement TryIt()
    {
        var panel = new StackPanel();
        panel.Children.Add(SectionTitle(ui.Text("collaboration.try.title")));
        var rows = new[] { "review", "ask", "worktree" }.Select(key =>
        {
            string phrase = ui.Text("collaboration.try." + key);
            var label = Label(phrase, 13); label.TextWrapping = TextWrapping.Wrap;
            return (UIElement)Row(label, CopyButton(phrase, "settings.collaboration.try." + key), 40);
        }).ToArray();
        panel.Children.Add(Card(rows));
        return panel;
    }

    // ---------------------------------------------------------------- running, statistics, recent runs

    private FrameworkElement RunningCard(IReadOnlyList<RunningDelegation> running, int limit)
    {
        var panel = new StackPanel();
        panel.Children.Add(SectionTitle(ui.Text("collaboration.running.title") + " · " + ui.Text("collaboration.running.limit")
            .Replace("%1$d", running.Count.ToString()).Replace("%2$d", limit.ToString()).ReplaceFirst("%d", running.Count.ToString()).ReplaceFirst("%d", limit.ToString())));
        var rows = running.Select(item =>
        {
            var row = new Grid { Margin = new Thickness(14, 8, 10, 8) };
            row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(Label(item.Row.Title, 13, FontWeights.SemiBold));
            text.Children.Add(Detail(item.ParentTitle));
            row.Children.Add(text);
            var numbers = Detail(string.Join(" · ", new[] { item.Row.TurnTime, item.Row.RateText is { } rate ? rate + " t/s" : null,
                item.Row.Model + (item.Row.Effort is { } effort ? " " + effort : "") }.Where(part => !string.IsNullOrEmpty(part))));
            numbers.VerticalAlignment = VerticalAlignment.Center; numbers.Margin = new Thickness(10, 0, 10, 0);
            Grid.SetColumn(numbers, 1); row.Children.Add(numbers);
            var stop = new Button { Content = ui.Text("delegation.stop"), VerticalAlignment = VerticalAlignment.Center, IsEnabled = item.Row.CanStop == true };
            Identify(stop, "settings.collaboration.stop." + item.Row.Id, ui.Text("delegation.stop"));
            stop.Click += async (_, _) => { stop.IsEnabled = false; await SendDelegation("stopDelegation", new { activityID = item.Row.Id }); };
            Grid.SetColumn(stop, 2); row.Children.Add(stop);
            return (UIElement)row;
        }).ToArray();
        panel.Children.Add(Card(rows));
        return panel;
    }

    private FrameworkElement StatisticsCard(DelegationStatistics stats, string? quota, int days)
    {
        var panel = new StackPanel();
        // The section title carries the 7 / 30 day choice.
        var title = new DockPanel { Margin = new Thickness(0, 6, 0, 8), LastChildFill = false };
        var heading = SectionTitle(ui.Text("collaboration.stats.title")); heading.Margin = new Thickness(0); title.Children.Add(heading);
        var choice = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(choice, Dock.Right);
        foreach (int value in new[] { 7, 30 })
        {
            var option = new RadioButton { Content = ui.Text("collaboration.stats.days").Replace("%d", value.ToString()), GroupName = "settings.collaboration.days",
                IsChecked = value == days, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Identify(option, "settings.collaboration.days." + value, (string)option.Content);
            option.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { CodexDelegationStatsDays = value }); };
            choice.Children.Add(option);
        }
        title.Children.Add(choice); panel.Children.Add(title);

        var tiles = new System.Windows.Controls.Primitives.UniformGrid { Columns = 4, Margin = new Thickness(10, 12, 10, 4) };
        foreach (var kpi in stats.Kpis)
        {
            var tile = new StackPanel { Margin = new Thickness(4, 0, 4, 0) };
            var name = Detail(kpi.Title); name.FontSize = 11.5; tile.Children.Add(name);
            tile.Children.Add(Label(kpi.Value, 20, FontWeights.SemiBold));
            if (kpi.Note != null)
            {
                var note = Detail(kpi.Note); note.FontSize = 11; note.TextWrapping = TextWrapping.Wrap;
                if (ToneKey(kpi.Tone) is { } key) note.SetResourceReference(TextBlock.ForegroundProperty, key);
                tile.Children.Add(note);
            }
            AutomationProperties.SetName(tile, kpi.Title + " " + kpi.Value + (kpi.Note == null ? "" : ", " + kpi.Note));
            tiles.Children.Add(tile);
        }

        var legend = new WrapPanel { Margin = new Thickness(14, 10, 14, 2) };
        foreach (var key in new[] { "ok", "stopped", "failed" })
        {
            var swatch = new Rectangle { Width = 8, Height = 8, RadiusX = 2, RadiusY = 2, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
            Paint(swatch, key);
            var item = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 12, 0) };
            item.Children.Add(swatch); var text = Detail(ui.Text("collaboration.stats." + key)); text.FontSize = 11; item.Children.Add(text);
            legend.Children.Add(item);
        }
        if (quota != null)
        {
            var text = Detail(ui.Text("collaboration.stats.quota") + "  " + quota); text.FontSize = 11; text.Margin = new Thickness(8, 0, 0, 0);
            legend.Children.Add(text);
        }

        // One bar per day, stacked done / stopped / failed, on one scale.
        const double chartHeight = 92;
        var bars = new Grid { Height = chartHeight, Margin = new Thickness(14, 6, 14, 0) };
        for (int index = 0; index < stats.Chart.Count; index++)
        {
            bars.ColumnDefinitions.Add(new ColumnDefinition());
            var day = stats.Chart[index];
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(1.5, 0, 1.5, 0) };
            foreach (var (count, key) in new[] { (day.Failed, "failed"), (day.Stopped, "stopped"), (day.Ok, "ok") })
                if (count > 0)
                {
                    var bar = new Rectangle { Height = Math.Max(2, count / (double)stats.ChartMax * chartHeight), RadiusX = 1.5, RadiusY = 1.5 };
                    Paint(bar, key); stack.Children.Add(bar);
                }
            stack.ToolTip = day.Label + " · " + ui.Text("collaboration.stats.ok") + " " + day.Ok + " · " + ui.Text("collaboration.stats.stopped") + " " + day.Stopped
                + " · " + ui.Text("collaboration.stats.failed") + " " + day.Failed;
            stack.Background = Brushes.Transparent; stack.MinHeight = chartHeight;
            Grid.SetColumn(stack, index); bars.Children.Add(stack);
        }
        var baseline = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; baseline.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        var axis = new Grid { Margin = new Thickness(14, 3, 14, 8) };
        if (stats.Chart.Count > 0)
        {
            var first = Detail(stats.Chart[0].Label); first.FontSize = 10.5; axis.Children.Add(first);
            var last = Detail(stats.Chart[^1].Label); last.FontSize = 10.5; last.HorizontalAlignment = HorizontalAlignment.Right; axis.Children.Add(last);
            var middle = Detail(stats.Chart[stats.Chart.Count / 2].Label); middle.FontSize = 10.5; middle.HorizontalAlignment = HorizontalAlignment.Center; axis.Children.Add(middle);
        }

        var shares = new System.Windows.Controls.Primitives.UniformGrid { Columns = Math.Max(1, stats.Breakdowns.Count), Margin = new Thickness(10, 6, 10, 12) };
        foreach (var breakdown in stats.Breakdowns)
        {
            var column = new StackPanel { Margin = new Thickness(4, 0, 8, 0) };
            var name = Detail(breakdown.Title); name.FontSize = 11.5; name.FontWeight = FontWeights.SemiBold; name.Margin = new Thickness(0, 0, 0, 4); column.Children.Add(name);
            foreach (var share in breakdown.Shares)
            {
                var line = new Grid { Margin = new Thickness(0, 2, 0, 2) };
                line.ColumnDefinitions.Add(new ColumnDefinition()); line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
                var text = new StackPanel();
                var label = Label(share.Name, 11.5); label.TextTrimming = TextTrimming.CharacterEllipsis; text.Children.Add(label);
                var track = new Grid { Height = 5, Margin = new Thickness(0, 2, 0, 0) };
                var back = new Border { CornerRadius = new CornerRadius(2.5) }; back.SetResourceReference(Border.BackgroundProperty, "SettingsSearchFill"); track.Children.Add(back);
                track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, share.Fraction), GridUnitType.Star) });
                track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0, 1 - share.Fraction), GridUnitType.Star) });
                Grid.SetColumnSpan(back, 2);
                track.Children.Add(new Border { CornerRadius = new CornerRadius(2.5), Background = PacerPalette.Provider("codex") });
                text.Children.Add(track);
                line.Children.Add(text);
                var count = Detail(share.Count.ToString()); count.HorizontalAlignment = HorizontalAlignment.Right; count.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(count, 1); line.Children.Add(count);
                AutomationProperties.SetName(line, share.Name + " " + share.Count);
                column.Children.Add(line);
            }
            shares.Children.Add(column);
        }
        var body = new StackPanel(); body.Children.Add(tiles); body.Children.Add(legend); body.Children.Add(bars); body.Children.Add(baseline); body.Children.Add(axis); body.Children.Add(shares);
        Identify(body, "settings.collaboration.statistics", stats.Summary);
        panel.Children.Add(Card(body));
        return panel;
    }

    private FrameworkElement RecentCard(DelegationStatistics stats)
    {
        var panel = new StackPanel();
        var title = new DockPanel { Margin = new Thickness(0, 6, 0, 8), LastChildFill = false };
        var heading = SectionTitle(ui.Text("collaboration.recent.title")); heading.Margin = new Thickness(0); title.Children.Add(heading);
        var clear = new Button { Content = ui.Text("collaboration.recent.clear"), Style = (Style)FindResource("SettingsLink"), VerticalAlignment = VerticalAlignment.Center,
            Visibility = stats.Recent.Any(run => run.Project != null) ? Visibility.Visible : Visibility.Collapsed };
        Identify(clear, "settings.collaboration.recent.clear", ui.Text("collaboration.recent.clear"));
        clear.Click += async (_, _) => await SendDelegation("clearDelegationHistory");
        DockPanel.SetDock(clear, Dock.Right); title.Children.Add(clear); panel.Children.Add(title);
        if (stats.Recent.Count == 0)
        {
            var empty = Detail(ui.Text("collaboration.recent.empty")); empty.Margin = new Thickness(14, 12, 14, 12); empty.TextWrapping = TextWrapping.Wrap;
            panel.Children.Add(Card(empty)); return panel;
        }
        var rows = stats.Recent.Take(10).Select(run =>
        {
            var row = new Grid { Margin = new Thickness(14, 6, 14, 6) };
            foreach (var width in new[] { new GridLength(52), new GridLength(1.6, GridUnitType.Star), new GridLength(1, GridUnitType.Star), new GridLength(72), GridLength.Auto })
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            var time = Detail(run.Time); time.FontSize = 11.5; time.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(time);
            var name = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12.5 };
            name.Inlines.Add(new System.Windows.Documents.Run(run.Title));
            if (run.Project != null) { var project = new System.Windows.Documents.Run(" · " + run.Project) { FontSize = 11.5 }; project.SetResourceReference(TextElement.ForegroundProperty, "SettingsSecondary"); name.Inlines.Add(project); }
            Grid.SetColumn(name, 1); row.Children.Add(name);
            var detail = Detail(run.Detail); detail.FontSize = 11.5; detail.TextTrimming = TextTrimming.CharacterEllipsis; detail.VerticalAlignment = VerticalAlignment.Center;
            detail.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(detail, 2); row.Children.Add(detail);
            var duration = Detail(run.Duration); duration.FontSize = 11.5; duration.VerticalAlignment = VerticalAlignment.Center; duration.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(duration, 3); row.Children.Add(duration);
            var result = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(7, 0, 7, 1), Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            var resultText = Label(run.Result, 10.5, FontWeights.SemiBold);
            var tint = run.Tone == "ok" ? PacerPalette.Provider("codex") : TryFindResource(run.Tone == "failed" ? "SettingsErrorText" : "SettingsSecondary") as Brush ?? PacerPalette.Secondary;
            resultText.Foreground = tint;
            result.Background = tint is SolidColorBrush solid ? new SolidColorBrush(Color.FromArgb(38, solid.Color.R, solid.Color.G, solid.Color.B)) : Brushes.Transparent;
            result.Child = resultText; Grid.SetColumn(result, 4); row.Children.Add(result);
            AutomationProperties.SetName(row, string.Join(", ", new[] { run.Time, run.Title, run.Project, run.Detail, run.Duration, run.Result }.Where(s => !string.IsNullOrEmpty(s))));
            return (UIElement)row;
        }).ToArray();
        panel.Children.Add(Card(rows));
        return panel;
    }

    // ---------------------------------------------------------------- checks

    private FrameworkElement ChecksCard(CodexDelegationStatus? status, bool editable)
    {
        var panel = new StackPanel();
        var title = new DockPanel { Margin = new Thickness(0, 6, 0, 8), LastChildFill = false };
        var heading = SectionTitle(ui.Text("collaboration.section.checks")); heading.Margin = new Thickness(0); title.Children.Add(heading);
        var check = new Button { Content = ui.Text(status?.Checking == true ? "collaboration.check.running" : "collaboration.check.run"), IsEnabled = status?.Checking != true && engine != null,
            VerticalAlignment = VerticalAlignment.Center };
        Identify(check, "settings.collaboration.check", ui.Text("collaboration.check.run"));
        check.Click += async (_, _) => { check.IsEnabled = false; await SendDelegation("checkCodexDelegation"); };
        DockPanel.SetDock(check, Dock.Right); title.Children.Add(check); panel.Children.Add(title);

        TextBlock State(string text, string? tone, string id)
        {
            var value = Detail(text); Identify(value, id, text);
            if (ToneKey(tone) is { } key) value.SetResourceReference(TextBlock.ForegroundProperty, key);
            return value;
        }
        UIElement Pair(UIElement value, UIElement? action)
        {
            if (action == null) return value;
            var both = new StackPanel { Orientation = Orientation.Horizontal };
            if (value is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
            both.Children.Add(value);
            if (action is FrameworkElement end) end.Margin = new Thickness(10, 0, 0, 0);
            both.Children.Add(action); return both;
        }
        string program = status?.CodexFound == false ? ui.Text("collaboration.codex_missing")
            : status?.Version is { } version ? ui.Text("collaboration.check.version").Replace("%@", version) : ui.Text("collaboration.codex_found");
        var rows = new System.Collections.Generic.List<UIElement>
        {
            InfoRow(ui.Text("collaboration.codex_program"), State(program, status?.CodexFound == false ? "warn" : "good", "settings.collaboration.codex")),
            InfoRow(ui.Text("collaboration.check.login"), Pair(State(ui.Text(status?.Login switch { "ok" => "collaboration.status.signed_in", "missing" => "collaboration.status.signed_out", _ => "collaboration.check.login_unknown" }),
                status?.Login switch { "ok" => "good", "missing" => "warn", _ => null }, "settings.collaboration.login"),
                status?.Login == "missing" ? ActionButton(ui.Text("collaboration.check.open_codex"), "settings.collaboration.open_codex", OpenCodexApplication) : null)),
            InfoRow(ui.Text("collaboration.skill"), Pair(State(ui.Text(status?.SkillInstalled == true ? "collaboration.check.skill_new_sessions" : session.Current.CodexDelegation ? "collaboration.skill_waiting" : "collaboration.check.skill_missing"),
                status?.SkillInstalled == true ? "good" : null, "settings.collaboration.skill"),
                session.Current.CodexDelegation ? ActionButton(ui.Text("collaboration.check.reinstall"), "settings.collaboration.reinstall", () => _ = SendDelegation("reinstallDelegationSkill")) : null))
        };
        if (status?.LegacySkill is { } legacy)
        {
            var remove = ActionButton(ui.Text("collaboration.legacy_remove"), "settings.collaboration.legacy_remove", RemoveLegacySkill);
            remove.IsEnabled = editable;
            var path = Detail(legacy); path.TextWrapping = TextWrapping.Wrap;
            rows.Add(InfoRow(ui.Text("collaboration.legacy"), remove, ui.Text("collaboration.info.legacy"), path, "settings.collaboration.legacy"));
        }
        if (status?.RunsFolder is { } folder)
        {
            var open = ActionButton(ui.Text("collaboration.check.open_folder"), "settings.collaboration.open_folder", () =>
            {
                try { using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", "\"" + folder.Replace('/', '\\') + "\"") { UseShellExecute = false }); }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { ShowIssue("windows.pages.open_failed"); }
            });
            rows.Add(InfoRow(ui.Text("collaboration.check.pending"), Pair(State((status.Pending).ToString(), status.Pending > 0 ? "warn" : null, "settings.collaboration.pending"), open)));
        }
        panel.Children.Add(Card(rows.ToArray()));
        return panel;
    }

    /// The earlier user-level skill goes to the Recycle Bin, where the user can
    /// restore it; only the exact folder the engine reported is touched.
    private void RemoveLegacySkill()
    {
        if (engine?.LatestSnapshot?.CodexDelegation?.LegacySkill is not { Length: > 0 } path) return;
        string full = System.IO.Path.GetFullPath(path);
        bool known = System.IO.Path.GetFileName(full.TrimEnd('\\', '/')) == "codex"
            && string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(full.TrimEnd('\\', '/'))), "skills", StringComparison.OrdinalIgnoreCase);
        if (!known || !Directory.Exists(full) || !RecycleBin.Send(full)) { ShowIssue("collaboration.legacy_failed"); return; }
        ClearIssue();
        delegationSignature = null;
    }
}

internal static class DelegationText
{
    /// Replaces the first occurrence only, for printf-style shared strings with several `%d`.
    internal static string ReplaceFirst(this string text, string placeholder, string value)
    {
        int index = text.IndexOf(placeholder, StringComparison.Ordinal);
        return index < 0 ? text : text[..index] + value + text[(index + placeholder.Length)..];
    }
}

/// Moves a file or folder to the Recycle Bin without asking, so the user can restore it.
internal static class RecycleBin
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Operation
    {
        public IntPtr Window;
        public uint Function;
        public string From;
        public string? To;
        public ushort Flags;
        public int Aborted;
        public IntPtr Mappings;
        public string? Title;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref Operation operation);
    private const uint Delete = 3;
    private const ushort Silent = 0x0004, NoConfirmation = 0x0010, AllowUndo = 0x0040, NoErrorUI = 0x0400, NoConfirmMakeDirectory = 0x0200;
    internal static bool Send(string path)
    {
        var operation = new Operation { Function = Delete, From = path + "\0\0", Flags = Silent | NoConfirmation | AllowUndo | NoErrorUI | NoConfirmMakeDirectory };
        return SHFileOperationW(ref operation) == 0 && operation.Aborted == 0 && !Directory.Exists(path) && !File.Exists(path);
    }
}
