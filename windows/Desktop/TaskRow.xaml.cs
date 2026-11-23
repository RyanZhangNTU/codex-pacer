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
    /// Each Codex for Claude run under a Claude task takes one 30-point line.
    internal const double DelegationHeight = 30, DelegationRailBottom = 4;
    internal static double RowHeight(PanelOptions? options) => options?.OneLine == true ? OneLineHeight : TwoLineHeight;
    /// The row with the runs listed under it.
    internal static double RowHeight(EngineTaskRow value, PanelOptions? options) => RowHeight(options) +
        (value.Delegations is { Count: > 0 } runs ? runs.Count * DelegationHeight + DelegationRailBottom : 0);
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
        BuildDelegations(value, options);
        // The one-line row's icon draws the 28-point face at 22.
        if (state.OneLine) Icon.LayoutTransform = new ScaleTransform(22.0 / 28, 22.0 / 28);
        Background = PacerPalette.Hover; IsEnabled = false;
        Click += (_, _) => { if (IsEnabled) open?.Invoke(); };
        // The task highlights while the pointer is on its own row; over the Codex runs under it,
        // only the run under the pointer lights up.
        MouseEnter += (_, _) => { hovered = !Runs.IsMouseOver; UpdateHover(); };
        MouseLeave += (_, _) => { hovered = false; UpdateHover(); };
        Runs.MouseEnter += (_, _) => { hovered = false; UpdateHover(); };
        Runs.MouseLeave += (_, _) => { hovered = IsMouseOver; UpdateHover(); };
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
        BuildDelegations(value, options);
        var before = previous.Value;
        if (progressShown && (before.Symbol != value.Symbol || before.Dimmed != value.Dimmed || before.ProgressState != value.ProgressState
            || before.ProgressMode != value.ProgressMode || before.ProgressFraction != value.ProgressFraction || before.ProgressStale != value.ProgressStale
            || IconColor(previous) != IconColor(state)))
            ShowProgress();
    }
    /// The row's status icon; read by the presentation checks.
    internal TaskStatusIcon StatusIcon => Icon;
    internal void SetOpenAction(Action? action, string help, bool animate)
    { open = action; IsEnabled = action != null; Focusable = IsEnabled; AutomationProperties.SetHelpText(this, help); animations = animate; UpdateHover(); Icon.SetMotion(animate); }
    internal void SetAnimations(bool value)
    {
        animations = value; Icon.SetMotion(value); if (!value) UpdateHover();
        foreach (var icon in Delegations.Children.OfType<Grid>().SelectMany(line => line.Children.OfType<TaskStatusIcon>())) icon.SetMotion(value);
    }
    /// Stop on a running Codex for Claude run's line; the island sends the run's ID.
    internal void SetStopAction(Action<string>? action, string label) { stop = action; stopLabel = label; RefreshStopButtons(); }
    private void RefreshStopButtons()
    {
        foreach (var line in Delegations.Children.OfType<Grid>())
            if (line.Tag is EngineTaskRow run && line.Children.OfType<Button>().FirstOrDefault() is { } button)
            {
                AutomationProperties.SetName(button, stopLabel);
                bool shown = stop != null && run.CanStop == true && line.IsMouseOver;
                button.Visibility = shown ? Visibility.Visible : Visibility.Hidden;
                // No room is kept for Stop: it lies over the line's end, and the readings fade out beneath it.
                if (line.Children.OfType<TextBlock>().FirstOrDefault(text => Grid.GetColumn(text) == ReadingsColumn) is { } readings)
                    readings.OpacityMask = shown ? FadeUnderStop(readings.ActualWidth) : null;
            }
    }
    private const int ReadingsColumn = 4;
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
         line.Children.OfType<TextBlock>().FirstOrDefault(text => Grid.GetColumn(text) == ReadingsColumn)?.OpacityMask != null);
    /// One line per run: its icon (state and progress ring), Claude's label,
    /// speed and time, model and effort, always on the line; no hover card.
    /// Screen readers get the run's details as help text. Clicking the line
    /// opens the Claude task, like the row.
    private void BuildDelegations(EngineTaskRow value, PanelOptions? options)
    {
        Delegations.Children.Clear();
        var runs = showsDelegations ? value.Delegations : null;
        Runs.Visibility = runs is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        if (runs == null) return;
        foreach (var run in runs)
        {
            var state = new TaskRowState(run, options);
            var line = new Grid { Height = DelegationHeight, Tag = run, Background = Brushes.Transparent };
            // Icon, gap, label, gap, readings; Stop has no column of its own and lies over the readings' end on hover.
            foreach (var width in new[] { new GridLength(20), new GridLength(8), new GridLength(1, GridUnitType.Star), new GridLength(10), GridLength.Auto })
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            // The line's own highlight, a smaller rounded fill than the task's, as on the Mac.
            var highlight = new Border { CornerRadius = new CornerRadius(8), Background = PacerPalette.Hover, Opacity = 0, IsHitTestVisible = false, Margin = new Thickness(-4, 0, 0, 0) };
            Grid.SetColumnSpan(highlight, 5); line.Children.Add(highlight);
            var icon = new TaskStatusIcon { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                LayoutTransform = new ScaleTransform(20.0 / 28, 20.0 / 28) };
            line.Children.Add(icon);
            var text = new TextBlock { Text = run.Title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = state.TitleInk,
                VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(text, 2); line.Children.Add(text);
            var trailing = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Opacity = state.ModelOpacity, Margin = new Thickness(0, 0, 4, 0) };
            // Speed, time, model and effort, as on a task row's two lines.
            if (run.RateText != null)
            {
                trailing.Inlines.Add(new System.Windows.Documents.Run(run.RateText) { FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = state.RateInk });
                trailing.Inlines.Add(new System.Windows.Documents.Run(" t/s" + (run.TurnTime != null ? " · " : "  ")) { FontSize = 10, FontWeight = FontWeights.Medium, Foreground = PacerPalette.Secondary });
            }
            if (run.TurnTime != null)
                trailing.Inlines.Add(new System.Windows.Documents.Run(run.TurnTime + "  ") { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = state.DurationInk });
            trailing.Inlines.Add(new System.Windows.Documents.Run(run.Model) { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = state.ProviderInk });
            if (run.Effort != null)
                trailing.Inlines.Add(new System.Windows.Documents.Run(" " + run.Effort) { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = state.ProviderInk });
            Grid.SetColumn(trailing, ReadingsColumn); line.Children.Add(trailing);
            var button = StopButton(run); button.Margin = new Thickness(0, 0, 2, 0);
            Grid.SetColumn(button, 2); Grid.SetColumnSpan(button, 3); line.Children.Add(button);
            line.MouseEnter += (_, _) => { RefreshStopButtons(); RefreshLineHighlight(line); };
            line.MouseLeave += (_, _) => { RefreshStopButtons(); RefreshLineHighlight(line); };
            AutomationProperties.SetName(line, state.AccessibleName);
            if (run.DetailLines is { Count: > 0 } lines)
                AutomationProperties.SetHelpText(line, string.Join(", ", lines.Where(pair => pair.Count == 2).Select(pair => pair[0] + " " + pair[1])));
            Delegations.Children.Add(line);
            icon.Show(run, IconColor(state), false);
            icon.SetMotion(animations);
        }
        RefreshStopButtons();
    }
    /// A run line lights up only while it is hovered and the task can be opened.
    private void RefreshLineHighlight(Grid line)
    {
        if (line.Children.OfType<Border>().FirstOrDefault() is { } highlight)
            highlight.Opacity = line.IsMouseOver && IsEnabled && !DesktopAppearance.GetHighContrast(this) ? 1 : 0;
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
        double target = hovered && IsEnabled && !DesktopAppearance.GetHighContrast(this) ? 1 : 0, from = HoverProgress; int revision = ++hoverRevision;
        hover?.Dispose(); hover = null; HoverProgress = target;
        if (!animations || from == target) return;
        var timing = NativeTaskRowTiming.Shared;
        var animation = new DoubleAnimation(from, target, TimeSpan.FromSeconds(timing.Duration)) { EasingFunction = timing.Ease };
        hover = new(animation, clock => ApplyAnimationClock(HoverProgressProperty, clock), () => { if (revision == hoverRevision) hover = null; });
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new RowPeer(this);
    /// The row reads as one button; a running Codex for Claude run adds its Stop
    /// button, which screen readers reach without hovering.
    private sealed class RowPeer(TaskRow owner) : ButtonAutomationPeer(owner)
    {
        protected override List<AutomationPeer>? GetChildrenCore()
        {
            var stops = owner.StopButtons().Select(button => UIElementAutomationPeer.CreatePeerForElement(button)).OfType<AutomationPeer>().ToList();
            return stops.Count == 0 ? null : stops;
        }
    }
    private IEnumerable<Button> StopButtons() => stop == null ? [] : Delegations.Children.OfType<Grid>()
        .Where(line => line.Tag is EngineTaskRow { CanStop: true }).SelectMany(line => line.Children.OfType<Button>());
    internal double IdealWidth()
    {
        var state = (TaskRowState)DataContext;
        double Text(string? value, double size, FontWeight weight) => string.IsNullOrEmpty(value) ? 0 :
            new FormattedText(value, PacerFonts.Culture(this), FlowDirection.LeftToRight,
                new Typeface(FontFamily, FontStyles.Normal, weight, FontStretches.Normal), size, Brushes.White,
                VisualTreeHelper.GetDpi(this).PixelsPerDip).WidthIncludingTrailingWhitespace;
        var row = state.Value;
        double trailing = state.OneLineStatusVisible == Visibility.Visible ? Text(row.Status, 11, FontWeights.Medium)
            : Text(state.ShownRateText, state.RateSize, FontWeights.SemiBold) + Text(state.ShownRateUnit + state.ShownSeparator + state.ShownTurnTime, 11, FontWeights.Medium);
        double title = Math.Min(200, Text(row.Title, 13, FontWeights.SemiBold)) + (trailing > 0 ? 16 + trailing : 0);
        if (state.OneLine) return 22 + 10 + 18 + title;
        double model = (state.ModelVisible == Visibility.Visible ? Text(row.Model, 11, FontWeights.Medium) : 0)
            + (state.EffortVisible == Visibility.Visible ? Text(row.Effort, 11, FontWeights.Medium) + 4 : 0)
            + (state.CostVisible == Visibility.Visible ? Text(row.Cost, 11, FontWeights.Medium) + (row.PeakCost ? 16 : 7) : 0);
        double detail = Text(row.Status, 11, FontWeights.Medium)
            + (state.SubagentsVisible == Visibility.Visible ? 24 + Text(row.SubagentText ?? "—", 11, FontWeights.Medium) : 0)
            + (state.SourceVisible == Visibility.Visible ? 10 + Text(row.SourceLabel, 11, FontWeights.Medium) + (row.SourceKind == null ? 0 : 14) : 0)
            + (state.DelegatedVisible == Visibility.Visible ? 20 + Text(row.DelegatedText, 10, FontWeights.SemiBold) : 0);
        double runs = 0;
        foreach (var run in showsDelegations ? row.Delegations ?? [] : [])
            runs = Math.Max(runs, 22 + 12 + 20 + 8 + Math.Min(220, Text(run.Title, 12, FontWeights.SemiBold))
                + 10 + Text((run.RateText == null ? "" : run.RateText + " t/s · ") + (run.TurnTime == null ? "" : run.TurnTime + "  ") + run.Model
                    + (run.Effort == null ? "" : " " + run.Effort), 11, FontWeights.Medium) + 4 + 6);
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
    public Visibility SubagentsVisible => Visible(Value.Subagents > 0 && choices.Shows("subagents"));
    public Visibility SourceVisible => Visible(Value.Source != null && choices.Shows("source"));
    public Visibility SourceIconVisible => Visible(Value.SourceKind != null);
    public Visibility CostVisible => Visible(Value.Cost != null && choices.Shows("cost"));
    public Visibility PeakVisible => Visible(Value.PeakCost);
    public Visibility EffortVisible => Visible(Value.Effort != null && choices.Shows("model"));
    public string SourceSymbol => Value.SourceKind == "cloud" ? "cloud" : "server.rack";

    public string AccessibleName => string.Join(", ", new[] { Value.Provider, Value.Title, Value.Status, Value.ProgressText, Value.Source,
        Value.Model, Value.Effort, RateText + RateUnit, Value.TurnTime, Value.Cost }.Where(s => !string.IsNullOrEmpty(s)));
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
}
