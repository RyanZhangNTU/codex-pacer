using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media.Effects;

namespace CodexPacer.Windows;

/// Settings → Collaboration, as on the Mac: the pairs first, one card each with
/// its switch; then the selected pair's settings, the basic ones and the
/// advanced ones folded away. Claude → Codex is the only pair so far. Every
/// choice applies at once and only shapes how Codex runs; explanations wait
/// behind ⓘ. Codex's own state (version, sign-in) lives on its module page, so
/// the pair card names only what keeps it from working, with the one step that
/// fixes it.
internal sealed partial class SettingsWindow
{
    private CheckBox? pairSwitch, delegationMemory;
    private StackPanel? pairProblem, delegationAdvanced;
    private string? pairProblemSignature, legacyIssue;
    private Button? delegationRestore, delegationInstructionsEdit;
    private ComboBox? delegationTrigger, delegationModel, delegationEffort, delegationFast, delegationHours, delegationSandbox,
        delegationConcurrency, delegationQuotaFloor;
    private TextBox? delegationModelField;
    private TextBlock? delegationModelDefault, delegationEffortDefault, delegationFastDefault, delegationInstructions;
    private Expander? delegationAdvancedRow;
    private readonly Dictionary<string, RadioButton> delegationSegments = new();

    private void ClearCollaboration()
    {
        pairSwitch = delegationMemory = null; pairProblem = delegationAdvanced = null; pairProblemSignature = legacyIssue = null;
        delegationRestore = delegationInstructionsEdit = null;
        delegationTrigger = delegationModel = delegationEffort = delegationFast = delegationHours = delegationSandbox = delegationConcurrency = delegationQuotaFloor = null;
        delegationModelField = null; delegationModelDefault = delegationEffortDefault = delegationFastDefault = delegationInstructions = null;
        delegationAdvancedRow = null; delegationSegments.Clear();
    }

    private void BuildCollaboration()
    {
        paneSubtitle.Text = ui.Text("main.subtitle.collaboration"); paneSubtitle.Visibility = Visibility.Visible;
        // Pairs sit two to a row; Claude → Codex is the only one so far.
        form.Children.Add(SectionTitle(ui.Text("collab.pairs")));
        var pairs = new UniformGrid { Columns = 2, Margin = new Thickness(0, 0, 0, 22) };
        pairs.Children.Add(PairCard());
        form.Children.Add(pairs);
        BuildDelegationBasic();
        BuildDelegationAdvanced();
        RefreshCollaboration();
        // Codex's version, sign-in, models and its own defaults, read each time the page opens.
        if (engine != null) _ = SendDelegation("checkCodexDelegation");
    }

    // ---------------------------------------------------------------- pairs

    private Border PairCard()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // Claude's icon with Codex's over its corner.
        var icons = new Canvas { Width = 38, Height = 30, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        var claude = ProviderIcon.Tile("claude", 24, GuideArt.ProviderSymbol("claude"));
        var codex = ProviderIcon.Tile("codex", 22, GuideArt.ProviderSymbol("codex")); Canvas.SetLeft(codex, 14); Canvas.SetTop(codex, 7);
        icons.Children.Add(claude); icons.Children.Add(codex);
        grid.Children.Add(icons);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Label(ui.Text("collab.pair.claude_codex"), 13.5, FontWeights.SemiBold));
        pairProblem = new StackPanel(); text.Children.Add(pairProblem);
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        pairSwitch = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        Identify(pairSwitch, "settings.collaboration.enabled", ui.Text("collab.pair.claude_codex"));
        BindToggle(pairSwitch, (p, value) => p with { CodexDelegation = value }); editors.Add(pairSwitch);
        Grid.SetColumn(pairSwitch, 2); grid.Children.Add(pairSwitch);
        // The selected pair carries the accent outline.
        var card = new Border { Child = grid, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1.5), Margin = new Thickness(0, 0, 5, 0) };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        Identify(card, "settings.collaboration.pair.claude_codex", ui.Text("collab.pair.claude_codex"));
        return card;
    }

    /// What keeps the pair from working, with the one step that fixes it.
    private (string Text, string? Action)? PairProblem(CodexDelegationStatus? status, bool claude, DesktopPreferences current)
    {
        if (!claude) return (ui.Text("collab.reason.claude_off"), null);
        // A folder just moved to the Recycle Bin is gone before the engine's next look.
        if (status?.LegacySkill is { Length: > 0 } legacy && Directory.Exists(legacy)) return (legacyIssue ?? ui.Text("collab.reason.legacy"), "legacy");
        if (status?.CodexFound == false) return (ui.Text("collab.reason.codex_missing"), "codex");
        if (status?.Login == "missing") return (ui.Text("collab.reason.signed_out"), "signIn");
        if (current.CodexDelegation && status is { SkillInstalled: false }) return (ui.Text("collab.reason.setup"), "retry");
        return null;
    }

    private void RefreshPairProblem(CodexDelegationStatus? status, bool claude, DesktopPreferences current, bool usable)
    {
        var problem = PairProblem(status, claude, current);
        string signature = problem == null ? "" : problem.Value.Text + "|" + problem.Value.Action + "|" + usable;
        if (signature == pairProblemSignature) return;
        pairProblemSignature = signature;
        pairProblem!.Children.Clear();
        if (problem is not { } value) return;
        var line = Label(value.Text, 11.5); line.TextWrapping = TextWrapping.Wrap; line.Margin = new Thickness(0, 4, 0, 0);
        line.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        Identify(line, "settings.collaboration.pair.reason", value.Text); AutomationProperties.SetLiveSetting(line, AutomationLiveSetting.Polite);
        pairProblem.Children.Add(line);
        string? label = value.Action switch
        {
            "legacy" => ui.Text("windows.collab.legacy_remove"), "codex" => ui.Text("collab.go_codex"),
            "signIn" => ui.Text("collab.open_codex"), "retry" => ui.Text("collab.retry"), _ => null
        };
        if (label == null) return;
        var action = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), IsEnabled = usable };
        Identify(action, "settings.collaboration.pair.action", label);
        string kind = value.Action!;
        action.Click += async (_, _) =>
        {
            switch (kind)
            {
                case "legacy": RemoveLegacySkill(); break;
                case "codex": await NavigateAsync("codex"); break;
                case "signIn": OpenCodexApplication(); break;
                case "retry": await SendDelegation("reinstallDelegationSkill"); break;
            }
        };
        pairProblem.Children.Add(action);
    }

    // ---------------------------------------------------------------- basic

    private void BuildDelegationBasic()
    {
        delegationRestore = new Button { Content = ui.Text("common.restore_defaults"), Style = (Style)FindResource("SettingsLink"), FontSize = 12 };
        Identify(delegationRestore, "settings.collaboration.restore", ui.Text("common.restore_defaults"));
        // Only this pair's choices go back; its switch stays.
        delegationRestore.Click += async (_, _) => await Change(p => p.RestoringDelegationDefaults());
        editors.Add(delegationRestore);
        form.Children.Add(SectionHeader(ui.Text("collab.basic"), delegationRestore));

        delegationTrigger = DelegationMenu("trigger", ui.Text("collab.trigger"),
            DesktopPreferences.DelegationTriggers.Select(value => (value, ui.Text("collab.trigger." + value))), (p, value) => p with { CodexDelegationTrigger = value });
        var trigger = InfoRow(ui.Text("collab.trigger"), delegationTrigger, ui.Text("collab.info.trigger"), id: "settings.collaboration.trigger_row");

        // Model, effort and fast mode follow Codex until the user picks; the picker shows only then.
        delegationModel = DelegationMenu("model", ui.Text("collab.model"), [], (p, value) => p with { CodexDelegationModel = value }, 150);
        delegationModelField = new TextBox { Width = 150, MaxLength = 80, VerticalAlignment = VerticalAlignment.Center, Tag = "gpt-…" };
        Identify(delegationModelField, "settings.collaboration.model_field", ui.Text("collab.model")); editors.Add(delegationModelField);
        delegationModelField.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitDelegationModel(); } };
        delegationModelField.LostKeyboardFocus += async (_, _) => { if (!composing) await CommitDelegationModel(); };
        delegationModelDefault = Detail("");
        var model = InfoRow(ui.Text("collab.model"), Trailing(delegationModel, delegationModelField,
            FollowSegments("model", ui.Text("collab.model"), pick => p => p with
            {
                CodexDelegationFollowModel = !pick,
                // Picking starts from Codex's own model, the first time.
                CodexDelegationModel = pick && p.CodexDelegationModel.Length == 0 ? FallbackModel() : p.CodexDelegationModel
            })), detail: delegationModelDefault, id: "settings.collaboration.model_row");

        delegationEffort = DelegationMenu("effort", ui.Text("collab.effort"), [], (p, value) => p with { CodexDelegationEffort = value }, 110);
        delegationEffortDefault = Detail("");
        var effort = InfoRow(ui.Text("collab.effort"), Trailing(delegationEffort,
            FollowSegments("effort", ui.Text("collab.effort"), pick => p => p with
            {
                CodexDelegationFollowEffort = !pick,
                CodexDelegationEffort = pick && p.CodexDelegationEffort == new DesktopPreferences().CodexDelegationEffort
                    && engine?.LatestSnapshot?.CodexDelegation?.DefaultEffort is { } codexEffort && DesktopPreferences.DelegationEfforts.Contains(codexEffort)
                    ? codexEffort : p.CodexDelegationEffort
            })), detail: delegationEffortDefault, id: "settings.collaboration.effort_row");

        delegationFast = DelegationMenu("fast", ui.Text("collab.fast"), [("on", ui.Text("collab.on")), ("off", ui.Text("collab.off"))],
            (p, value) => p with { CodexDelegationFast = value == "on" }, 90);
        delegationFastDefault = Detail("");
        var fast = InfoRow(ui.Text("collab.fast"), Trailing(delegationFast,
            FollowSegments("fast", ui.Text("collab.fast"), pick => p => p with
            {
                CodexDelegationFollowFast = !pick,
                CodexDelegationFast = pick && p.CodexDelegationFast == new DesktopPreferences().CodexDelegationFast
                    && engine?.LatestSnapshot?.CodexDelegation?.DefaultFast is bool codexFast ? codexFast : p.CodexDelegationFast
            })), detail: delegationFastDefault, id: "settings.collaboration.fast_row");

        delegationHours = DelegationMenu("records_hours", ui.Text("collab.records"),
            DesktopPreferences.DelegationRecordsHours.Select(hours => (hours.ToString(), DelegationDuration(hours))),
            (p, value) => p with { CodexDelegationRecordsHours = int.Parse(value) }, 90);
        var recordsHint = Detail(ui.Text("collab.records.hint"));
        var records = InfoRow(ui.Text("collab.records"), Trailing(delegationHours,
            DelegationSegments("records", ui.Text("collab.records"), DesktopPreferences.DelegationRecords.Select(value => (value, ui.Text("collab.records." + value))).ToArray(),
                value => Change(p => p with { CodexDelegationRecords = value }))),
            ui.Text("collab.info.records"), recordsHint, "settings.collaboration.records_row");
        form.Children.Add(Card(trigger, model, effort, fast, records));
    }

    private string FallbackModel()
    {
        var status = engine?.LatestSnapshot?.CodexDelegation;
        string value = status?.DefaultModel ?? status?.Models?.FirstOrDefault()?.Slug ?? "";
        return DesktopPreferences.ValidDelegationModel(value) ? value : "";
    }

    /// Follow Codex | Pick, for model, effort and fast mode.
    private Border FollowSegments(string group, string title, Func<bool, Func<DesktopPreferences, DesktopPreferences>> edit) =>
        DelegationSegments(group, title, [("follow", ui.Text("collab.follow")), ("pick", ui.Text("collab.pick"))],
            value => Change(edit(value == "pick")));

    private string DelegationDuration(int hours) => hours < 24 ? ui.Text("collab.hours").Replace("%d", hours.ToString(), StringComparison.Ordinal)
        : hours == 24 ? ui.Text("collab.day") : ui.Text("collab.days").Replace("%d", (hours / 24).ToString(), StringComparison.Ordinal);

    private async Task CommitDelegationModel()
    {
        if (synchronizing || sourceClosed || delegationModelField == null || activePane != "collaboration") return;
        string value = delegationModelField.Text.Trim();
        if (!DesktopPreferences.ValidDelegationModel(value)) { delegationModelField.Text = session.Current.CodexDelegationModel; return; }
        delegationModelField.Text = value;
        if (value != session.Current.CodexDelegationModel) await Change(p => p with { CodexDelegationModel = value });
    }

    // ---------------------------------------------------------------- advanced

    private void BuildDelegationAdvanced()
    {
        // One folded row with a summary; the three cards follow it while open.
        delegationAdvancedRow = Disclosure(ui.Text("collab.advanced"), new Border(), false, "settings.collaboration.advanced");
        delegationAdvanced = new StackPanel { Visibility = Visibility.Collapsed };
        delegationAdvancedRow.Expanded += (_, _) => { if (delegationAdvanced != null) delegationAdvanced.Visibility = Visibility.Visible; };
        delegationAdvancedRow.Collapsed += (_, _) => { if (delegationAdvanced != null) delegationAdvanced.Visibility = Visibility.Collapsed; };
        form.Children.Add(Card(delegationAdvancedRow));

        delegationSandbox = DelegationMenu("sandbox", ui.Text("collab.sandbox"),
            DesktopPreferences.DelegationSandboxes.Select(value => (value, ui.Text("collab.sandbox." + value))), (p, value) => p with { CodexDelegationSandbox = value }, 180);
        var location = DelegationSegments("location", ui.Text("collab.location"),
            [("project", ui.Text("collab.location.project")), ("worktree", ui.Text("collab.location.worktree"))],
            value => Change(p => p with { CodexDelegationWorktree = value == "worktree" }));
        delegationAdvanced.Children.Add(SectionTitle(ui.Text("collab.section.access")));
        delegationAdvanced.Children.Add(Card(
            InfoRow(ui.Text("collab.sandbox"), delegationSandbox, ui.Text("collab.info.sandbox"), id: "settings.collaboration.sandbox_row"),
            InfoRow(ui.Text("collab.location"), location, ui.Text("collab.info.location"), id: "settings.collaboration.location_row")));

        delegationInstructions = Label("", 12.5); delegationInstructions.TextTrimming = TextTrimming.CharacterEllipsis; delegationInstructions.MaxWidth = 220;
        delegationInstructions.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Identify(delegationInstructions, "settings.collaboration.instructions", "");
        delegationInstructionsEdit = new Button { Content = ui.Text("collab.edit"), VerticalAlignment = VerticalAlignment.Center };
        Identify(delegationInstructionsEdit, "settings.collaboration.instructions.edit", ui.Text("collab.edit") + " " + ui.Text("collab.instructions"));
        editors.Add(delegationInstructionsEdit);
        var editor = InstructionsEditor(delegationInstructionsEdit);
        delegationInstructionsEdit.Click += (_, _) => editor.IsOpen = true;
        var memory = Toggle("collab.memory", "collab.info.memory", "settings.collaboration.memory", out var memorySwitch);
        delegationMemory = memorySwitch; editors.Add(memorySwitch);
        BindToggle(memorySwitch, (p, value) => p with { CodexDelegationMemory = value });
        delegationAdvanced.Children.Add(SectionTitle(ui.Text("collab.section.context")));
        delegationAdvanced.Children.Add(Card(
            InfoRow(ui.Text("collab.instructions"), Trailing(delegationInstructions, delegationInstructionsEdit, editor), ui.Text("collab.info.instructions"),
                id: "settings.collaboration.instructions_row"), memory));

        delegationConcurrency = DelegationMenu("concurrency", ui.Text("collab.concurrency"),
            DesktopPreferences.DelegationConcurrency.Select(value => (value.ToString(), value.ToString())), (p, value) => p with { CodexDelegationConcurrency = int.Parse(value) }, 70);
        delegationQuotaFloor = DelegationMenu("quota_floor", ui.Text("collab.quota_floor"),
            DesktopPreferences.DelegationQuotaFloors.Select(value => (value.ToString(), value == 0 ? ui.Text("collab.quota_floor.none") : value + "%")),
            (p, value) => p with { CodexDelegationQuotaFloor = int.Parse(value) }, 90);
        delegationAdvanced.Children.Add(SectionTitle(ui.Text("collab.section.limits")));
        delegationAdvanced.Children.Add(Card(
            InfoRow(ui.Text("collab.concurrency"), delegationConcurrency, detail: Detail(ui.Text("collab.concurrency.hint")), id: "settings.collaboration.concurrency_row"),
            InfoRow(ui.Text("collab.quota_floor"), delegationQuotaFloor, detail: Detail(ui.Text("collab.quota_floor.hint")), id: "settings.collaboration.quota_floor_row")));
        form.Children.Add(delegationAdvanced);
    }

    /// The standing instructions open in a box under Edit; Done saves them, Cancel or Escape leaves them.
    private Popup InstructionsEditor(Button anchor)
    {
        var box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Width = 340, Height = 150, MaxLength = DesktopPreferences.DelegationInstructionsLimit,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalContentAlignment = VerticalAlignment.Top };
        Identify(box, "settings.collaboration.instructions.text", ui.Text("collab.instructions"));
        var placeholder = Label(ui.Text("collab.instructions.placeholder"), 12.5); placeholder.IsHitTestVisible = false;
        placeholder.VerticalAlignment = VerticalAlignment.Top; placeholder.Margin = new Thickness(7, 5, 7, 0); placeholder.TextWrapping = TextWrapping.Wrap;
        placeholder.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        box.TextChanged += (_, _) => placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var field = new Grid(); field.Children.Add(box); field.Children.Add(placeholder);
        var cancel = new Button { Content = ui.Text("common.cancel"), Margin = new Thickness(0, 0, 8, 0) };
        Identify(cancel, "settings.collaboration.instructions.cancel", ui.Text("common.cancel"));
        var done = new Button { Content = ui.Text("collab.done"), Style = (Style)FindResource("SettingsProminentButton") };
        Identify(done, "settings.collaboration.instructions.done", ui.Text("collab.done"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        buttons.Children.Add(cancel); buttons.Children.Add(done);
        var content = new StackPanel();
        var title = Label(ui.Text("collab.instructions"), 13, FontWeights.SemiBold); title.Margin = new Thickness(0, 0, 0, 10);
        content.Children.Add(title); content.Children.Add(field); content.Children.Add(buttons);
        var surface = new Border { Child = content, Padding = new Thickness(14), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Margin = new Thickness(10),
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.25, Direction = 270 } };
        surface.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); surface.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        var popup = new Popup { Child = surface, PlacementTarget = anchor, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true };
        popup.Opened += (_, _) =>
        {
            box.Text = session.Current.CodexDelegationInstructions; box.CaretIndex = box.Text.Length;
            Dispatcher.BeginInvoke(() => box.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        };
        // Escape closes the box, not the window.
        surface.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && !composing) { popup.IsOpen = false; e.Handled = true; } };
        cancel.Click += (_, _) => popup.IsOpen = false;
        done.Click += async (_, _) =>
        {
            string text = DesktopPreferences.CleanDelegationInstructions(box.Text);
            popup.IsOpen = false;
            if (text != session.Current.CodexDelegationInstructions) await Change(p => p with { CodexDelegationInstructions = text });
        };
        return popup;
    }

    // ---------------------------------------------------------------- pieces

    /// A section title with a control at its end, like the Mac card's title trailing.
    private DockPanel SectionHeader(string text, FrameworkElement trailing)
    {
        var header = new DockPanel { Margin = new Thickness(4, 0, 4, 8) };
        trailing.VerticalAlignment = VerticalAlignment.Center; DockPanel.SetDock(trailing, Dock.Right); header.Children.Add(trailing);
        var title = SectionTitle(text); title.Margin = new Thickness(0); header.Children.Add(title);
        return header;
    }

    /// A row's controls side by side, the last one at the row's end; one that is hidden takes no room.
    private static StackPanel Trailing(params FrameworkElement[] parts)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var shown = parts.Where(part => part is not Popup).ToArray();
        foreach (var part in parts)
        {
            if (part is not Popup)
            {
                part.VerticalAlignment = VerticalAlignment.Center;
                part.Margin = ReferenceEquals(part, shown[^1]) ? new Thickness(0) : new Thickness(0, 0, 8, 0);
            }
            panel.Children.Add(part);
        }
        return panel;
    }

    private ComboBox DelegationMenu(string id, string name, IEnumerable<(string Value, string Label)> choices,
        Func<DesktopPreferences, string, DesktopPreferences> write, double minWidth = 140)
    {
        var box = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = minWidth, MaxWidth = 260, SelectedValuePath = "Tag" };
        SetMenuChoices(box, choices);
        Identify(box, "settings.collaboration." + id, name);
        box.SelectionChanged += async (_, _) => { if (!synchronizing && box.SelectedValue is string value) await Change(p => write(p, value)); };
        editors.Add(box);
        return box;
    }

    private static void SetMenuChoices(ComboBox box, IEnumerable<(string Value, string Label)> choices)
    {
        var wanted = choices.ToArray();
        var existing = box.Items.OfType<ComboBoxItem>().Select(item => ((string)item.Tag, (string)item.Content)).ToArray();
        if (existing.SequenceEqual(wanted)) return;
        box.Items.Clear();
        foreach (var (value, label) in wanted) box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
    }

    private Border DelegationSegments(string group, string title, (string Value, string Label)[] options, Func<string, Task> change)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var (value, label) in options)
        {
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), GroupName = "collaboration." + group, Content = label };
            Identify(choice, "settings.collaboration." + group + "." + value, title + ": " + label);
            choice.Checked += async (_, _) => { if (!synchronizing) await change(value); };
            delegationSegments[group + "." + value] = choice; row.Children.Add(choice); editors.Add(choice);
        }
        var border = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        border.SetResourceReference(Border.BackgroundProperty, "SettingsFill");
        return border;
    }

    private void PickSegment(string group, string value, bool enabled)
    {
        foreach (var (key, choice) in delegationSegments)
            if (key.StartsWith(group + ".", StringComparison.Ordinal)) { choice.IsChecked = key == group + "." + value; choice.IsEnabled = enabled; }
    }

    private void SetCodexDefault(TextBlock hint, string? value)
    {
        hint.Text = value == null ? "" : ui.Text("collab.codex_default").Replace("%@", value, StringComparison.Ordinal);
        hint.Visibility = value == null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(hint, hint.Text);
    }

    private async Task SendDelegation(string method, object? parameters = null)
    {
        if (engine == null || sourceClosed) return;
        try { await engine.SendAsync(method, parameters); }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException) { }
    }

    // ---------------------------------------------------------------- refresh

    private void RefreshCollaboration()
    {
        if (pairSwitch == null || engine == null) return;
        var snapshot = engine.LatestSnapshot;
        var status = snapshot?.CodexDelegation;
        var current = session.Current;
        bool claude = snapshot?.Modules?.FirstOrDefault(module => module.Provider == "claude")?.Enabled == true;
        bool connected = !providerConnectionClosed && !engine.IsConnectionClosed && snapshot != null;
        bool usable = connected && !busy && !session.RequiresRestart;
        // The switch and the choices need the Claude module; the page stays readable without it.
        bool editable = usable && claude;
        pairSwitch.IsChecked = current.CodexDelegation; pairSwitch.IsEnabled = editable;
        RefreshPairProblem(status, claude, current, usable);
        delegationRestore!.IsEnabled = editable && !current.DelegationIsDefault;
        delegationTrigger!.SelectedValue = current.CodexDelegationTrigger;

        // The model list is Codex's catalog, with a saved model it no longer lists kept choosable; until it is known, a field.
        var models = status?.Models ?? [];
        string ModelName(string slug) => models.FirstOrDefault(model => model.Slug == slug)?.Name ?? slug;
        SetCodexDefault(delegationModelDefault!, status?.DefaultModel is { Length: > 0 } codexModel ? ModelName(codexModel) : null);
        SetMenuChoices(delegationModel!, models.Select(model => (model.Slug, model.Name))
            .Concat(current.CodexDelegationModel.Length > 0 && models.All(model => model.Slug != current.CodexDelegationModel)
                ? new[] { (current.CodexDelegationModel, current.CodexDelegationModel) } : Array.Empty<(string, string)>()));
        delegationModel!.SelectedValue = current.CodexDelegationModel;
        delegationModel.Visibility = !current.CodexDelegationFollowModel && models.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        delegationModelField!.Visibility = !current.CodexDelegationFollowModel && models.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (!delegationModelField.IsKeyboardFocusWithin) delegationModelField.Text = current.CodexDelegationModel;
        PickSegment("model", current.CodexDelegationFollowModel ? "follow" : "pick", editable);

        // The efforts the chosen (or Codex's) model supports, else every level.
        SetCodexDefault(delegationEffortDefault!, status?.DefaultEffort);
        string? slug = current.CodexDelegationFollowModel ? status?.DefaultModel : current.CodexDelegationModel;
        var supported = models.FirstOrDefault(model => model.Slug == slug)?.Efforts;
        var efforts = (supported is { Count: > 0 } ? supported : DesktopPreferences.DelegationEfforts).ToList();
        if (!efforts.Contains(current.CodexDelegationEffort)) efforts.Add(current.CodexDelegationEffort);
        SetMenuChoices(delegationEffort!, efforts.Select(value => (value, value)));
        delegationEffort!.SelectedValue = current.CodexDelegationEffort;
        delegationEffort.Visibility = current.CodexDelegationFollowEffort ? Visibility.Collapsed : Visibility.Visible;
        PickSegment("effort", current.CodexDelegationFollowEffort ? "follow" : "pick", editable);

        SetCodexDefault(delegationFastDefault!, status?.DefaultFast is bool codexFast ? ui.Text(codexFast ? "collab.on" : "collab.off") : null);
        delegationFast!.SelectedValue = current.CodexDelegationFast ? "on" : "off";
        delegationFast.Visibility = current.CodexDelegationFollowFast ? Visibility.Collapsed : Visibility.Visible;
        PickSegment("fast", current.CodexDelegationFollowFast ? "follow" : "pick", editable);

        PickSegment("records", current.CodexDelegationRecords, editable);
        delegationHours!.SelectedValue = current.CodexDelegationRecordsHours.ToString();
        delegationHours.Visibility = current.CodexDelegationRecords == "timed" ? Visibility.Visible : Visibility.Collapsed;

        delegationAdvancedRow!.Tag = ui.Text(current.DelegationAdvancedIsDefault ? "collab.advanced.summary" : "collab.advanced.summary_changed");
        delegationSandbox!.SelectedValue = current.CodexDelegationSandbox;
        // A read-only run changes nothing, so where it would work doesn't apply.
        PickSegment("location", current.CodexDelegationWorktree ? "worktree" : "project", editable && current.CodexDelegationSandbox != "read-only");
        string instructions = current.CodexDelegationInstructions.Length == 0 ? ui.Text("collab.instructions.none")
            : string.Join(" ", current.CodexDelegationInstructions.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
        delegationInstructions!.Text = instructions; AutomationProperties.SetName(delegationInstructions, instructions);
        delegationMemory!.IsChecked = current.CodexDelegationMemory;
        delegationConcurrency!.SelectedValue = current.CodexDelegationConcurrency.ToString();
        delegationQuotaFloor!.SelectedValue = current.CodexDelegationQuotaFloor.ToString();
        foreach (var editor in new Control[] { delegationTrigger, delegationModel, delegationModelField, delegationEffort, delegationFast, delegationHours,
                     delegationSandbox, delegationInstructionsEdit!, delegationMemory, delegationConcurrency, delegationQuotaFloor })
            editor.IsEnabled = editable;
    }

    /// The earlier user-level skill goes to the Recycle Bin, where the user can
    /// restore it; only the exact folder the engine reported is touched.
    private void RemoveLegacySkill()
    {
        if (engine?.LatestSnapshot?.CodexDelegation?.LegacySkill is not { Length: > 0 } path) return;
        string full = System.IO.Path.GetFullPath(path);
        bool known = System.IO.Path.GetFileName(full.TrimEnd('\\', '/')) == "codex"
            && string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(full.TrimEnd('\\', '/'))), "skills", StringComparison.OrdinalIgnoreCase);
        legacyIssue = !known || !Directory.Exists(full) || !RecycleBin.Send(full) ? ui.Text("collaboration.legacy_failed") : null;
        pairProblemSignature = null;
        RefreshCollaboration();
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
