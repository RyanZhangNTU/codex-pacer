using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Collections.Generic;

namespace CodexPacer.Windows;

public partial class TaskRow : Button
{
    public static readonly DependencyProperty HoverProgressProperty = DependencyProperty.Register(nameof(HoverProgress), typeof(double), typeof(TaskRow),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double HoverProgress { get => (double)GetValue(HoverProgressProperty); set => SetValue(HoverProgressProperty, value); }
    private Action? open;
    private Action<string>? stop;
    private string stopLabel = "";
    private bool hovered, animations = true;
    private readonly bool showsDelegations;
    private int hoverRevision;
    private AnimationLease? hover;
    /// Rows with one line are 38 points tall, two lines 54.
    internal const double TwoLineHeight = 54, OneLineHeight = 38;
    /// Each Codex for Claude run under a Claude task takes one 30-point line, the
    /// older ended runs folded together a 22-point one; the rail ends 4 points below the last.
    internal const double DelegationHeight = 30, FoldedHeight = 22, DelegationRailBottom = 4;
    internal static double RowHeight(PanelOptions? options) => options?.OneLine == true ? OneLineHeight : TwoLineHeight;
    /// The row with the runs listed under it.
    internal static double RowHeight(EngineTaskRow value, PanelOptions? options)
    {
        int runs = value.Delegations?.Count ?? 0; bool folded = value.DelegationsFolded != null;
        return RowHeight(options) + SubagentHeight(value, options)
            + (runs == 0 && !folded ? 0 : runs * DelegationHeight + (folded ? FoldedHeight : 0) + DelegationRailBottom);
    }
    /// A task's subagent lines show with its subagents field, sized as its Codex runs.
    internal static double SubagentHeight(EngineTaskRow value, PanelOptions? options)
    {
        if (!(options ?? PanelOptions.Default).Shows("subagents")) return 0;
        int lines = value.SubagentLines?.Count ?? 0; bool folded = value.SubagentsFolded != null;
        return lines == 0 && !folded ? 0 : lines * DelegationHeight + (folded ? FoldedHeight : 0) + DelegationRailBottom;
    }
    /// <param name="options">The panel's row style and fields; none draws every field on two lines.</param>
    /// <param name="settled">The first sight draws the icon's final state, as a row built while hidden does.</param>
    /// <param name="showsDelegations">The island lists a Claude task's Codex runs under it; Overview keeps one line per task.</param>
    internal TaskRow(EngineTaskRow value, PanelOptions? options = null, bool settled = false, bool showsDelegations = false)
    {
        this.settled = settled; this.showsDelegations = showsDelegations;
        InitializeComponent();
        FontFamily = PacerFonts.Interface;
        var state = new TaskRowState(value, options);
        DataContext = state;
        Height = showsDelegations ? RowHeight(value, options) : RowHeight(options);
        BuildSubagents(value, options); BuildDots(state);
        BuildDelegations(value, options);
        FitReadings();
        Lines.SizeChanged += (_, args) => { if (args.WidthChanged) FitReadings(); };
        // The one-line row's icon draws the 28-point face at 22.
        if (state.OneLine) Icon.LayoutTransform = new ScaleTransform(22.0 / 28, 22.0 / 28);
        Background = PacerPalette.Hover; IsEnabled = false; Focusable = false;
        Click += (_, _) => { if (IsEnabled) open?.Invoke(); };
        // The task highlights while the pointer is on its own row; over the subagents or
        // Codex runs under it, only the line under the pointer lights up.
        MouseEnter += (_, _) => { hovered = !Runs.IsMouseOver && !SubagentRuns.IsMouseOver; UpdateHover(); };
        MouseLeave += (_, _) => { hovered = false; UpdateHover(); };
        foreach (var lines in new[] { Runs, SubagentRuns })
        {
            lines.MouseEnter += (_, _) => { hovered = false; UpdateHover(); };
            lines.MouseLeave += (_, _) => { hovered = IsMouseOver && !Runs.IsMouseOver && !SubagentRuns.IsMouseOver; UpdateHover(); };
        }
        Unloaded += (_, _) => { hovered = false; hoverRevision++; hover?.Dispose(); hover = null; HoverProgress = 0; };
        Loaded += (_, _) => { ApplyAppearance(); if (!progressShown) { progressShown = true; ShowProgress(); } };
    }
    private bool progressShown, settled;
    /// The ring and the state share one 28-pt icon, as on the Mac.
    private void ShowProgress()
    {
        var state = (TaskRowState)DataContext;
        bool animate = animations && IsVisible;
        Icon.Show(state.Value, IconColor(state), animate && !settled);
        // A settled first sight still runs the face's own loops.
        if (settled && animate) Icon.SetMotion(true);
        settled = false;
    }
    private static Color IconColor(TaskRowState state) => state.StatusInk is SolidColorBrush solid ? solid.Color : PacerPalette.Neutral;
    /// Takes the same task's new values in place. Text and colours rebind; the
    /// icon is shown again only when its state or colour changed, so a new rate
    /// or turn time leaves its motion alone.
    internal void Update(EngineTaskRow value, PanelOptions? options)
    {
        var previous = (TaskRowState)DataContext;
        if (previous.Value == value && previous.OneLine == (options?.OneLine == true)) return;
        var state = new TaskRowState(value, options);
        DataContext = state;
        Height = showsDelegations ? RowHeight(value, options) : RowHeight(options);
        BuildSubagents(value, options); BuildDots(state);
        BuildDelegations(value, options);
        FitReadings();
        var before = previous.Value;
        if (progressShown && (before.Symbol != value.Symbol || before.Dimmed != value.Dimmed || before.ProgressState != value.ProgressState
            || before.ProgressMode != value.ProgressMode || before.ProgressFraction != value.ProgressFraction || before.ProgressStale != value.ProgressStale
            || IconColor(previous) != IconColor(state)))
            ShowProgress();
    }
    /// The row's status icon; read by the presentation checks.
    internal TaskStatusIcon StatusIcon => Icon;
    internal void SetOpenAction(Action? action, string help, bool animate)
    {
        open = action; Focusable = action != null; UpdateEnabled();
        AutomationProperties.SetHelpText(this, help); animations = animate; UpdateHover(); Icon.SetMotion(animate);
        foreach (var line in ChildLines) RefreshLineHighlight(line);
    }
    /// The subagent lines, then the Codex run lines, each with its folded line.
    private IEnumerable<Grid> ChildLines => Subagents.Children.OfType<Grid>().Concat(Delegations.Children.OfType<Grid>());
    // Disabling the whole row also disables its Stop buttons.
    private void UpdateEnabled() => IsEnabled = open != null || StopButtons().Any();
    internal void SetAnimations(bool value)
    {
        animations = value; Icon.SetMotion(value); if (!value) UpdateHover();
        foreach (var icon in ChildLines.SelectMany(line => line.Children.OfType<TaskStatusIcon>())) icon.SetMotion(value);
    }
    /// Stop on a running Codex for Claude run's line; the island sends the run's ID.
    internal void SetStopAction(Action<string>? action, string label) { stop = action; stopLabel = label; UpdateEnabled(); RefreshStopButtons(); }
    private void RefreshStopButtons()
    {
        foreach (var line in Delegations.Children.OfType<Grid>())
            if (line.Tag is EngineTaskRow run && line.Children.OfType<Button>().FirstOrDefault() is { } button)
            {
                AutomationProperties.SetName(button, stopLabel);
                bool shown = stop != null && run.CanStop == true && line.IsMouseOver;
                button.Visibility = shown ? Visibility.Visible : Visibility.Hidden;
                // No room is kept for Stop: it lies over the line's end, and the readings fade out beneath it.
                if (line.Children.OfType<TaskLinePanel>().FirstOrDefault()?.ShownReadings is { } readings)
                    readings.OpacityMask = shown ? FadeUnderStop(readings.ActualWidth) : null;
            }
    }
    /// Opaque up to a little before Stop, clear under it.
    private static Brush? FadeUnderStop(double width)
    {
        if (width <= 0) return null;
        double clear = Math.Clamp((width - StopCover) / width, 0, 1), fade = Math.Clamp((width - StopCover - 10) / width, 0, 1);
        return new LinearGradientBrush(new GradientStopCollection { new(Colors.Black, 0), new(Colors.Black, fade), new(Colors.Transparent, clear), new(Colors.Transparent, 1) },
            new Point(0, 0.5), new Point(1, 0.5));
    }
    /// How much of the line's end Stop covers: its 20-point face and a little air.
    internal const double StopCover = 24;
    /// Whether a run line's Stop shows, and whether its readings fade under it; read by the presentation checks.
    internal static (bool Stop, bool Faded) StopState(Grid line) =>
        (line.Children.OfType<Button>().FirstOrDefault()?.Visibility == Visibility.Visible,
         line.Children.OfType<TaskLinePanel>().FirstOrDefault()?.ShownReadings.OpacityMask != null);
    /// One line under a task, shared by its subagents and its Codex for Claude runs, as
    /// the Mac's ChildTaskLine: the icon (state and progress ring), the type and name
    /// tags, the title, then the speed, state, time and model, joined by " · ". A
    /// narrow line shrinks the title first, then drops the model, then the time.
    private (Grid Line, TaskStatusIcon Icon) ChildLine(EngineTaskRow row, object tag, string? typeTag, string? nameTag, string title,
        bool active, string? rate, bool fresh, string? status, Brush? statusInk, string? time, string? model)
    {
        var line = new Grid { Height = DelegationHeight, Tag = tag, Background = Brushes.Transparent };
        // Icon, gap, content; Stop has no column of its own and lies over the readings' end on hover.
        foreach (var width in new[] { new GridLength(20), new GridLength(8), new GridLength(1, GridUnitType.Star) })
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        // The line's own highlight, a smaller rounded fill than the task's, as on the Mac.
        var highlight = new Border { CornerRadius = new CornerRadius(8), Background = PacerPalette.Hover, Opacity = 0, IsHitTestVisible = false, Margin = new Thickness(-4, 0, 0, 0) };
        Grid.SetColumnSpan(highlight, 3); line.Children.Add(highlight);
        var icon = new TaskStatusIcon { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            LayoutTransform = new ScaleTransform(20.0 / 28, 20.0 / 28) };
        line.Children.Add(icon);
        StackPanel? tags = null;
        if (typeTag != null || nameTag != null)
        {
            tags = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            // The type takes the service's color while running and steps back once ended; the name always stays quiet.
            var tint = active ? PacerPalette.Provider(row.Provider) : PacerPalette.Secondary;
            if (typeTag != null) tags.Children.Add(LineTag(typeTag, tint, tint is SolidColorBrush solid ? PacerPalette.Ink(solid.Color.R, solid.Color.G, solid.Color.B, 41) : PacerPalette.Hover));
            if (nameTag != null)
            {
                var name = LineTag(nameTag, PacerPalette.Secondary, null);
                if (tags.Children.Count > 0) name.Margin = new Thickness(TaskLinePanel.TagGap, 0, 0, 0);
                tags.Children.Add(name);
            }
        }
        var label = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = active ? PacerPalette.Primary : PacerPalette.Secondary,
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        TextBlock Readings(bool showModel, bool showTime)
        {
            var text = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = PacerPalette.Secondary, VerticalAlignment = VerticalAlignment.Center };
            bool any = false;
            void Add(string value, Brush ink, bool strong = false) =>
                text.Inlines.Add(new System.Windows.Documents.Run(value) { Foreground = ink, FontWeight = strong ? FontWeights.SemiBold : FontWeights.Medium });
            if (rate != null) { Add(rate + " t/s", active && fresh ? PacerPalette.Primary : PacerPalette.Secondary, strong: true); any = true; }
            if (status != null) { Add(status, statusInk ?? PacerPalette.Secondary); any = true; }
            if (showTime && time != null) { if (any) Add(" · ", PacerPalette.Secondary); Add(time, PacerPalette.Secondary); any = true; }
            if (showModel && model != null) { if (any) Add(" · ", PacerPalette.Secondary); Add(model, active ? PacerPalette.Provider(row.Provider) : PacerPalette.Secondary); }
            return text;
        }
        // Only the variants that read differently: without a model, the full readings are already the shorter ones.
        var variants = new List<FrameworkElement> { Readings(true, true) };
        if (model != null) variants.Add(Readings(false, true));
        if (time != null) variants.Add(Readings(false, false));
        var content = new TaskLinePanel(tags, label, variants) { Margin = new Thickness(0, 0, 4, 0) };
        Grid.SetColumn(content, 2); line.Children.Add(content);
        line.MouseEnter += (_, _) => RefreshLineHighlight(line);
        line.MouseLeave += (_, _) => RefreshLineHighlight(line);
        return (line, icon);
    }
    /// A tag is at most 120 points wide with its padding; a longer one keeps its start and end.
    internal const double TagWidthLimit = 120, TagPadding = 6;
    /// A type or name on a child line: 10-point semibold in a 15-point capsule.
    private Border LineTag(string text, Brush ink, Brush? fill)
    {
        string shown = MiddleTrim(text, TagWidthLimit - 2 * TagPadding, value => Measure(value, 10, FontWeights.SemiBold));
        var tag = new Border { Height = 15, MaxWidth = TagWidthLimit, CornerRadius = new CornerRadius(7.5), Padding = new Thickness(TagPadding, 0, TagPadding, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = shown, FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = ink, VerticalAlignment = VerticalAlignment.Center } };
        if (fill != null) tag.Background = fill; else tag.SetResourceReference(Border.BackgroundProperty, "Island.Overlay05");
        return tag;
    }
    /// The text, or as much of its start and end as fits around an ellipsis, as the Mac's middle truncation.
    internal static string MiddleTrim(string text, double width, Func<string, double> measure)
    {
        if (measure(text) <= width) return text;
        var info = new StringInfo(text);
        int count = info.LengthInTextElements;
        string Join(int keep) => info.SubstringByTextElements(0, (keep + 1) / 2) + "…" + (keep / 2 == 0 ? "" : info.SubstringByTextElements(count - keep / 2, keep / 2));
        string best = "…";
        for (int low = 1, high = count - 1; low <= high;)
        {
            int keep = (low + high) / 2;
            string candidate = Join(keep);
            if (measure(candidate) <= width) { best = candidate; low = keep + 1; } else high = keep - 1;
        }
        return best;
    }
    /// One line per run: its mode as a tag, Claude's label, then speed, time and
    /// model with effort; no hover card. Screen readers get the run's details as
    /// help text. Clicking the line opens the Claude task, like the row. Every
    /// running run and the most recent ended ones show; the older ended runs fold
    /// into one short line above them that says how many, and how many failed.
    private void BuildDelegations(EngineTaskRow value, PanelOptions? options)
    {
        Delegations.Children.Clear();
        var runs = showsDelegations ? value.Delegations : null;
        string? folded = showsDelegations ? value.DelegationsFolded : null;
        Runs.Visibility = runs is { Count: > 0 } || folded != null ? Visibility.Visible : Visibility.Collapsed;
        if (folded != null) Delegations.Children.Add(FoldedLine(folded));
        if (runs == null) return;
        foreach (var run in runs)
        {
            var state = new TaskRowState(run, options);
            var (line, icon) = ChildLine(run, run, run.ModeTag, null, run.Title, RunActive(run), run.RateText, run.RateIsFresh, null, null, run.TurnTime,
                run.Model + (run.Effort != null ? " " + run.Effort : ""));
            var button = StopButton(run); button.Margin = new Thickness(0, 0, 2, 0);
            Grid.SetColumn(button, 2); line.Children.Add(button);
            line.MouseEnter += (_, _) => RefreshStopButtons();
            line.MouseLeave += (_, _) => RefreshStopButtons();
            AutomationProperties.SetName(line, state.AccessibleName);
            if (run.DetailLines is { Count: > 0 } lines)
                AutomationProperties.SetHelpText(line, string.Join(", ", lines.Where(pair => pair.Count == 2).Select(pair => pair[0] + " " + pair[1])));
            Delegations.Children.Add(line);
            icon.Show(run, IconColor(state), false);
            icon.SetMotion(animations);
        }
        RefreshStopButtons();
    }
    /// Whether a Codex for Claude run still works, as Core's isRunningDelegation.
    private static bool RunActive(EngineTaskRow run) => !run.Dimmed && run.Phase is not ("completed" or "interrupted");
    /// What needs the user, or a failure, keeps its color after the line ends; the rest stays secondary.
    private static Brush? SubagentStatusInk(EngineSubagentLine line) =>
        line.State is "approval" or "input" ? PacerPalette.Attention : line.State == "failed" ? PacerPalette.Danger : null;
    /// One line per subagent under the task while it works, on the same rail and
    /// layout as the Codex runs: its type and name as tags, its title, then its
    /// speed while it writes, its state, time and model. Running and waiting ones
    /// first, then the most recently ended; the rest fold into one quiet line under
    /// them. Clicking a line opens the task; no Stop, no hover card.
    private void BuildSubagents(EngineTaskRow value, PanelOptions? options)
    {
        Subagents.Children.Clear();
        bool shown = showsDelegations && (options ?? PanelOptions.Default).Shows("subagents");
        var lines = shown ? value.SubagentLines : null;
        string? folded = shown ? value.SubagentsFolded : null;
        SubagentRuns.Visibility = lines is { Count: > 0 } || folded != null ? Visibility.Visible : Visibility.Collapsed;
        foreach (var subagent in lines ?? [])
        {
            var state = new TaskRowState(subagent.Row, options);
            var (line, icon) = ChildLine(subagent.Row, subagent, subagent.TypeTag, subagent.NameTag, subagent.Title ?? subagent.Row.Title, subagent.IsActive,
                subagent.RateText, subagent.RateIsFresh, subagent.StatusText, SubagentStatusInk(subagent), subagent.Time, subagent.Model);
            AutomationProperties.SetName(line, subagent.AccessibilityText);
            Subagents.Children.Add(line);
            icon.Show(subagent.Row, IconColor(state), false);
            icon.SetMotion(animations);
        }
        if (folded != null) Subagents.Children.Add(FoldedLine(folded));
    }
    /// The task's subagents as dots after its state: lit in the service's color while
    /// running, the attention color while one waits for the user, the danger color if
    /// one failed, grey once done. The engine puts the most urgent first, so the dots a
    /// crowded row folds into "+n" are done ones: 8 dots in a two-line row, 5 in one line.
    private void BuildDots(TaskRowState state)
    {
        OneLineDots.Children.Clear(); TwoLineDots.Children.Clear();
        if (!state.HasDots) return;
        var person = new IconGlyph { Symbol = "person.2", Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 1, 0) };
        person.SetResourceReference(IconGlyph.InkProperty, "Island.Secondary");
        OneLineDots.Children.Add(person);
        foreach (var (target, limit) in new[] { (OneLineDots, CompactDotLimit), (TwoLineDots, DotLimit) })
        {
            AutomationProperties.SetName(target, state.Value.SubagentDotsText ?? "");
            var (shown, more) = Dots(state.Value, limit);
            foreach (var dot in shown)
            {
                var mark = new System.Windows.Shapes.Ellipse { Width = 5, Height = 5, VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(target.Children.Count == 0 ? 0 : 3, 0, 0, 0) };
                if (dot == "completed") mark.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Island.Tertiary");
                else mark.Fill = dot switch { "attention" => PacerPalette.Attention, "failed" => PacerPalette.Danger, _ => state.ProviderInk };
                target.Children.Add(mark);
            }
            if (more > 0)
            {
                var label = new TextBlock { Text = "+" + more.ToString(CultureInfo.InvariantCulture), FontSize = 10, FontWeight = FontWeights.Medium,
                    VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3, 0, 0, 0) };
                label.SetResourceReference(TextBlock.ForegroundProperty, "Island.Secondary");
                target.Children.Add(label);
            }
        }
    }
    /// The dots a two-line row draws, and a one-line row, as the Mac's subagentDotLimit and compactSubagentDotLimit.
    internal const int DotLimit = 8, CompactDotLimit = 5;
    /// The dots a row of `limit` draws, and how many more it folds into "+n".
    internal static (IReadOnlyList<string> Shown, int More) Dots(EngineTaskRow row, int limit)
    {
        var all = row.SubagentDots ?? [];
        return (all.Take(limit).ToArray(), Math.Max(0, all.Count - limit));
    }
    /// The width of the dots and their count after the person glyph.
    private static double DotsWidth(EngineTaskRow row, int limit, Func<string, double> text)
    {
        var (shown, more) = Dots(row, limit);
        return shown.Count * 8 - 3 + (more > 0 ? 3 + text("+" + more.ToString(CultureInfo.InvariantCulture)) : 0);
    }
    /// Marks the folded line among the run lines; read by the presentation checks.
    internal const string FoldedTag = "folded";
    /// The older ended runs as one quiet line: an ellipsis in the icon column and
    /// how many, and how many failed. Clicking it opens the Claude task, like a run line.
    private Grid FoldedLine(string text)
    {
        var line = new Grid { Height = FoldedHeight, Tag = FoldedTag, Background = Brushes.Transparent };
        foreach (var width in new[] { new GridLength(20), new GridLength(8), new GridLength(1, GridUnitType.Star) })
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var highlight = new Border { CornerRadius = new CornerRadius(7), Background = PacerPalette.Hover, Opacity = 0, IsHitTestVisible = false, Margin = new Thickness(-4, 0, 0, 0) };
        Grid.SetColumnSpan(highlight, 3); line.Children.Add(highlight);
        var dots = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (int index = 0; index < 3; index++)
        {
            var dot = new System.Windows.Shapes.Ellipse { Width = 2.4, Height = 2.4, Margin = new Thickness(index == 0 ? 0 : 1.4, 0, 0, 0) };
            dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Island.Tertiary");
            dots.Children.Add(dot);
        }
        line.Children.Add(dots);
        var label = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis };
        label.SetResourceReference(TextBlock.ForegroundProperty, "Island.Secondary");
        Grid.SetColumn(label, 2); line.Children.Add(label);
        line.MouseEnter += (_, _) => RefreshLineHighlight(line);
        line.MouseLeave += (_, _) => RefreshLineHighlight(line);
        AutomationProperties.SetName(line, text);
        return line;
    }
    /// A run line lights up only while it is hovered and the task can be opened.
    private void RefreshLineHighlight(Grid line)
    {
        if (line.Children.OfType<Border>().FirstOrDefault() is { } highlight)
            highlight.Opacity = line.IsMouseOver && open != null && IsEnabled && !DesktopAppearance.GetHighContrast(this) ? 1 : 0;
    }
    /// Whether a run line shows its highlight; read by the presentation checks.
    internal static bool LineHighlighted(Grid line) => line.Children.OfType<Border>().FirstOrDefault()?.Opacity > 0;
    private Button StopButton(EngineTaskRow run)
    {
        var face = new Grid { Width = 20, Height = 20 };
        face.Children.Add(new System.Windows.Shapes.Ellipse { Fill = PacerPalette.Hover });
        face.Children.Add(new System.Windows.Shapes.Rectangle { Width = 7, Height = 7, RadiusX = 1.5, RadiusY = 1.5, Fill = PacerPalette.Primary });
        var button = new Button { Content = face, Width = 20, Height = 20, Padding = new Thickness(0), BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand, Visibility = Visibility.Hidden,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, FocusVisualStyle = null };
        button.Template = new ControlTemplate(typeof(Button)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) };
        button.Click += (_, args) => { args.Handled = true; if (run.CanStop == true) stop?.Invoke(run.Id); };
        return button;
    }
    internal void ApplyAppearance() => UpdateHover();
    private void UpdateHover()
    {
        double target = hovered && open != null && IsEnabled && !DesktopAppearance.GetHighContrast(this) ? 1 : 0, from = HoverProgress; int revision = ++hoverRevision;
        hover?.Dispose(); hover = null; HoverProgress = target;
        if (!animations || open == null || from == target) return;
        var timing = NativeTaskRowTiming.Shared;
        var animation = new DoubleAnimation(from, target, TimeSpan.FromSeconds(timing.Duration)) { EasingFunction = timing.Ease };
        hover = new(animation, clock => ApplyAnimationClock(HoverProgressProperty, clock), () => { if (revision == hoverRevision) hover = null; });
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new RowPeer(this);
    /// The row reads as one button; a running Codex for Claude run adds its Stop
    /// button, which screen readers reach without hovering.
    private sealed class RowPeer(TaskRow owner) : ButtonAutomationPeer(owner)
    {
        public override object? GetPattern(PatternInterface pattern) =>
            pattern == PatternInterface.Invoke && owner.open == null && owner.IsEnabled ? null : base.GetPattern(pattern);
        protected override List<AutomationPeer>? GetChildrenCore()
        {
            var stops = owner.StopButtons().Select(button => UIElementAutomationPeer.CreatePeerForElement(button)).OfType<AutomationPeer>().ToList();
            return stops.Count == 0 ? null : stops;
        }
    }
    private IEnumerable<Button> StopButtons() => stop == null ? [] : Delegations.Children.OfType<Grid>()
        .Where(line => line.Tag is EngineTaskRow { CanStop: true }).SelectMany(line => line.Children.OfType<Button>());
    private double Measure(string? value, double size, FontWeight weight) => string.IsNullOrEmpty(value) ? 0 :
        new FormattedText(value, PacerFonts.Culture(this), FlowDirection.LeftToRight,
            new Typeface(FontFamily, FontStyles.Normal, weight, FontStretches.Normal), size, Brushes.White,
            VisualTreeHelper.GetDpi(this).PixelsPerDip).WidthIncludingTrailingWhitespace;
    /// Whether the task's first line dropped its time, and its second line its model and effort.
    internal bool DropsTime { get; private set; }
    internal bool DropsModel { get; private set; }
    /// A narrow row shrinks its title first, down to 48 points, as the Mac's TaskLineLayout.
    /// Each line then decides on its own width: the first drops the time, keeping the speed;
    /// the second drops the model and effort, keeping the cost.
    private void FitReadings()
    {
        var state = (TaskRowState)DataContext;
        double width = Lines.ActualWidth;
        bool dropTime = false, dropModel = false;
        if (width > 0)
        {
            var row = state.Value;
            double Text(string? value, double size, FontWeight weight) => Measure(value, size, weight);
            double title = Math.Min(TaskLinePanel.TitleMinimum, Text(row.Title, 13, FontWeights.SemiBold))
                + (state.OneLineDotsVisible == Visibility.Visible ? 8 + 12 + 3 + DotsWidth(row, CompactDotLimit, value => Text(value, 10, FontWeights.Medium)) : 0);
            // A one-line row whose state leads shows no time to drop.
            if (state.OneLineStatusVisible != Visibility.Visible && state.ShownTurnTime != null)
            {
                double rate = Text(state.ShownRateText, state.RateSize, FontWeights.SemiBold) + Text(state.ShownRateUnit, 10, FontWeights.Medium)
                    + Text(state.ShownSeparator + state.ShownTurnTime, 11, FontWeights.Medium);
                dropTime = width - 16 - rate < title - 0.5;
            }
            if (!state.OneLine && state.ModelVisible == Visibility.Visible)
            {
                double model = (state.CostVisible == Visibility.Visible ? Text(row.Cost, 11, FontWeights.Medium) + 7 + (row.PeakCost ? 9 : 0) : 0)
                    + Text(row.Model, 11, FontWeights.Medium) + (state.EffortVisible == Visibility.Visible ? 4 + Text(row.Effort, 11, FontWeights.Medium) : 0);
                dropModel = width - 16 - model < Math.Min(TaskLinePanel.TitleMinimum, Text(row.Status, 11, FontWeights.Medium)) - 0.5;
            }
        }
        DropsTime = dropTime; DropsModel = dropModel;
        TimeSeparator.Text = dropTime ? "" : state.ShownSeparator;
        TimeRun.Text = dropTime ? null : state.ShownTurnTime;
        ModelText.Visibility = !dropModel && state.ModelVisible == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        EffortText.Visibility = !dropModel && state.EffortVisible == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
    }
    /// What a child line's readings read in full: speed or state, then time and model.
    private static string ChildReadings(string? rate, string? status, string? time, string? model)
    {
        string head = (rate != null ? rate + " t/s" : "") + (status ?? "");
        return string.Join(" · ", new[] { head, time, model }.Where(part => !string.IsNullOrEmpty(part)));
    }
    internal double IdealWidth()
    {
        var state = (TaskRowState)DataContext;
        double Text(string? value, double size, FontWeight weight) => Measure(value, size, weight);
        var row = state.Value;
        double trailing = state.OneLineStatusVisible == Visibility.Visible ? Text(row.Status, 11, FontWeights.Medium)
            : Text(state.ShownRateText, state.RateSize, FontWeights.SemiBold) + Text(state.ShownRateUnit + state.ShownSeparator + state.ShownTurnTime, 11, FontWeights.Medium);
        double Dots(int limit) => DotsWidth(row, limit, value => Text(value, 10, FontWeights.Medium));
        double title = Math.Min(200, Text(row.Title, 13, FontWeights.SemiBold)) + (trailing > 0 ? 16 + trailing : 0)
            + (state.OneLineDotsVisible == Visibility.Visible ? 8 + 12 + 3 + Dots(CompactDotLimit) : 0);
        if (state.OneLine) return 22 + 10 + 18 + title;
        double model = (state.ModelVisible == Visibility.Visible ? Text(row.Model, 11, FontWeights.Medium) : 0)
            + (state.EffortVisible == Visibility.Visible ? Text(row.Effort, 11, FontWeights.Medium) + 4 : 0)
            + (state.CostVisible == Visibility.Visible ? Text(row.Cost, 11, FontWeights.Medium) + (row.PeakCost ? 16 : 7) : 0);
        double detail = Text(row.Status, 11, FontWeights.Medium)
            + (state.SubagentsVisible != Visibility.Visible ? 0 : state.HasDots ? 10 + 11 + 4 + Dots(DotLimit) : 24 + Text(row.SubagentText ?? "—", 11, FontWeights.Medium))
            + (state.SourceVisible == Visibility.Visible ? 10 + Text(row.SourceLabel, 11, FontWeights.Medium) + (row.SourceKind == null ? 0 : 14) : 0)
            + (state.DelegatedVisible == Visibility.Visible ? 20 + Text(row.DelegatedText, 10, FontWeights.SemiBold) : 0);
        // A child line widens the panel by its tags, each up to 120 points, its title from 48 to 220, and its full
        // readings, as the Mac's ChildTaskLine.
        double Tag(string? value) => value == null ? 0 : Math.Min(TagWidthLimit, Text(value, 10, FontWeights.SemiBold) + 2 * TagPadding);
        double Child(string? typeTag, string? nameTag, string title, string readings) => 22 + 12 + 20 + 8
            + Tag(typeTag) + Tag(nameTag) + (typeTag != null && nameTag != null ? TaskLinePanel.TagGap : 0)
            + (typeTag != null || nameTag != null ? TaskLinePanel.TagGap : 0) + Math.Clamp(Text(title, 12, FontWeights.SemiBold), TaskLinePanel.TitleMinimum, 220)
            + (readings.Length > 0 ? TaskLinePanel.Gap + Text(readings, 11, FontWeights.Medium) : 0) + 4 + 6;
        double runs = showsDelegations && row.DelegationsFolded != null ? 22 + 12 + 20 + 8 + Text(row.DelegationsFolded, 11, FontWeights.Medium) + 6 : 0;
        foreach (var run in showsDelegations ? row.Delegations ?? [] : [])
            runs = Math.Max(runs, Child(run.ModeTag, null, run.Title,
                ChildReadings(run.RateText, null, run.TurnTime, run.Model + (run.Effort == null ? "" : " " + run.Effort))));
        bool subagents = showsDelegations && state.ShowsSubagents;
        if (subagents && row.SubagentsFolded != null) runs = Math.Max(runs, 22 + 12 + 20 + 8 + Text(row.SubagentsFolded, 11, FontWeights.Medium) + 6);
        foreach (var line in subagents ? row.SubagentLines ?? [] : [])
            runs = Math.Max(runs, Child(line.TypeTag, line.NameTag, line.Title ?? line.Row.Title, ChildReadings(line.RateText, line.StatusText, line.Time, line.Model)));
        return Math.Max(runs, 28 + 10 + 18 + Math.Max(title, detail + (model > 0 ? 16 + model : 0)));
    }
}

internal sealed class TaskRowState(EngineTaskRow value, PanelOptions? options = null)
{
    private readonly PanelOptions choices = options ?? PanelOptions.Default;
    public EngineTaskRow Value { get; } = value;
    public bool OneLine => choices.OneLine;
    public GridLength IconColumn => new(OneLine ? 22 : 28);
    public GridLength GapRow => new(OneLine ? 0 : 3);
    public GridLength DetailRow => new(OneLine ? 0 : 15);
    public Visibility SecondLineVisible => Visible(!OneLine);
    /// The task's own line; its Codex for Claude runs follow below it.
    public double MainHeight => TaskRow.RowHeight(choices);
    public Visibility DelegatedVisible => Visible(Value.DelegatedText != null);
    public Brush DelegatedInk => PacerPalette.Provider("codex");
    public Brush DelegatedFill => DelegatedInk is SolidColorBrush solid ? PacerPalette.Ink(solid.Color.R, solid.Color.G, solid.Color.B, 40) : PacerPalette.Hover;
    /// One line shows what needs the user, or a failure, where the speed would be.
    public Visibility OneLineStatusVisible => Visible(OneLine && (Value.Attention != null || Value.Phase == "waitingForInput" || Value.Failed));
    public Visibility RateLineVisible => Visible(OneLineStatusVisible != Visibility.Visible);
    public string? ShownRateText => choices.Shows("rate") ? RateText : null;
    public string ShownRateUnit => choices.Shows("rate") ? RateUnit : "";
    public string? ShownTurnTime => choices.Shows("turnTime") ? Value.TurnTime : null;
    public string ShownSeparator => ShownTurnTime != null && ShownRateText != null ? " · " : "";
    public Visibility ModelVisible => Visible(choices.Shows("model"));
    public Brush ProviderInk => PacerPalette.Provider(Value.Provider);
    public Brush TitleInk => Value.Dimmed ? PacerPalette.Secondary : PacerPalette.Primary;
    public Brush DetailInk => Value.Attention != null || Value.Phase == "waitingForInput" ? PacerPalette.Attention
        : Value.Failed ? PacerPalette.Danger : PacerPalette.Secondary;
    public Brush StatusInk => Value.Attention != null || Value.Phase == "waitingForInput" ? PacerPalette.Attention
        : Value.Failed ? PacerPalette.Danger : Value.Dimmed ? PacerPalette.Secondary
        : Value.Phase == "interrupted" || Value.Symbol == "pause.circle" ? PacerPalette.Paused : Value.Phase is "running" or "completed" ? ProviderInk : PacerPalette.Secondary;
    public Brush RateInk => Value.RateIsFresh && !Value.Dimmed ? PacerPalette.Primary : PacerPalette.Secondary;
    private static readonly Brush DarkRunning = PacerPalette.Ink(245, 245, 245, 199), LightRunning = PacerPalette.Ink(29, 29, 31, 199);
    public Brush DurationInk => Value.Phase == "running" ? PacerPalette.Light ? LightRunning : DarkRunning : PacerPalette.Secondary;
    public string? RateText => Value.RateText ?? Value.RatePlaceholder;
    public int RateSize => Value.TokensPerSecond == null ? 11 : 13;
    public string RateUnit => Value.TokensPerSecond == null ? "" : " t/s";
    public string RateSeparator => Value.TurnTime != null && RateText != null ? " · " : "";
    public double ModelOpacity => Value.Dimmed ? 0.7 : 1;
    public bool ShowsSubagents => choices.Shows("subagents");
    /// A dot per subagent of the current turn; Claude cloud workers come as a count only.
    public bool HasDots => Value.SubagentDots is { Count: > 0 };
    public Visibility SubagentsVisible => Visible((HasDots || Value.Subagents > 0) && ShowsSubagents);
    public Visibility SubagentCountVisible => Visible(!HasDots);
    public Visibility SubagentDotsVisible => Visible(HasDots);
    /// A one-line row keeps the dots of a chosen subagents field, without the lines under it.
    public Visibility OneLineDotsVisible => Visible(OneLine && HasDots && choices.RowFields.Contains("subagents"));
    private bool DotsShown => OneLine ? OneLineDotsVisible == Visibility.Visible : HasDots && ShowsSubagents;
    public Visibility SourceVisible => Visible(Value.Source != null && choices.Shows("source"));
    public Visibility SourceIconVisible => Visible(Value.SourceKind != null);
    public Visibility CostVisible => Visible(Value.Cost != null && choices.Shows("cost"));
    public Visibility PeakVisible => Visible(Value.PeakCost);
    public Visibility EffortVisible => Visible(Value.Effort != null && choices.Shows("model"));
    public string SourceSymbol => Value.SourceKind == "cloud" ? "cloud" : "server.rack";

    public string AccessibleName => string.Join(", ", new[] { Value.Provider, Value.Title, Value.Status, Value.ProgressText,
        DotsShown ? Value.SubagentDotsText : null, Value.Source,
        Value.Model, Value.Effort, RateText + RateUnit, Value.TurnTime, Value.Cost }.Where(s => !string.IsNullOrEmpty(s)));
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
}
