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
    private bool hovered, animations = true;
    private int hoverRevision;
    private AnimationLease? hover;
    /// Rows with one line are 38 points tall, two lines 54.
    internal const double TwoLineHeight = 54, OneLineHeight = 38;
    internal static double RowHeight(PanelOptions? options) => options?.OneLine == true ? OneLineHeight : TwoLineHeight;
    /// <param name="options">The panel's row style and fields; none draws every field on two lines.</param>
    /// <param name="settled">The first sight draws the icon's final state, as a row built while hidden does.</param>
    internal TaskRow(EngineTaskRow value, PanelOptions? options = null, bool settled = false)
    {
        this.settled = settled;
        InitializeComponent();
        FontFamily = PacerFonts.Interface;
        var state = new TaskRowState(value, options);
        DataContext = state;
        Height = RowHeight(options);
        // The one-line row's icon draws the 28-point face at 22.
        if (state.OneLine) Icon.LayoutTransform = new ScaleTransform(22.0 / 28, 22.0 / 28);
        Background = PacerPalette.Hover; IsEnabled = false;
        Click += (_, _) => { if (IsEnabled) open?.Invoke(); };
        MouseEnter += (_, _) => { hovered = true; UpdateHover(); };
        MouseLeave += (_, _) => { hovered = false; UpdateHover(); };
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
    internal void SetAnimations(bool value) { animations = value; Icon.SetMotion(value); if (!value) UpdateHover(); }
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
    private sealed class RowPeer(TaskRow owner) : ButtonAutomationPeer(owner)
    { protected override List<AutomationPeer>? GetChildrenCore() => null; }
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
            + (state.SourceVisible == Visibility.Visible ? 10 + Text(row.SourceLabel, 11, FontWeights.Medium) + (row.SourceKind == null ? 0 : 14) : 0);
        return 28 + 10 + 18 + Math.Max(title, detail + (model > 0 ? 16 + model : 0));
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
