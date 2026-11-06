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
    internal TaskRow(EngineTaskRow value)
    {
        InitializeComponent();
        FontFamily = PacerFonts.Interface;
        DataContext = new TaskRowState(value);
        Background = PacerPalette.Hover; IsEnabled = false;
        Click += (_, _) => { if (IsEnabled) open?.Invoke(); };
        MouseEnter += (_, _) => { hovered = true; UpdateHover(); };
        MouseLeave += (_, _) => { hovered = false; UpdateHover(); };
        Unloaded += (_, _) => { hovered = false; hoverRevision++; hover?.Dispose(); hover = null; HoverProgress = 0; };
        Loaded += (_, _) => { ApplyAppearance(); if (!progressShown) { progressShown = true; ShowProgress(); } };
    }
    private bool progressShown;
    private readonly ScaleTransform glyphScale = new(1, 1);
    /// The icon gives the ring room: 20 pt alone, 16 pt inside the ring.
    private void ShowProgress()
    {
        var state = (TaskRowState)DataContext;
        var row = state.Value;
        var color = state.StatusInk is SolidColorBrush solid ? solid.Color : Colors.White;
        bool animate = animations && IsVisible;
        var change = Ring.Show(row.Id, row.ProgressState, row.ProgressMode, row.ProgressFraction ?? 0, row.ProgressStale == true, color, animate);
        Glyph.RenderTransform = glyphScale;
        double target = change is TaskProgressRing.Change.Appeared or TaskProgressRing.Change.Shown ? 0.8 : 1;
        double from = change switch { TaskProgressRing.Change.Appeared => 1, TaskProgressRing.Change.Disappeared => 0.8, _ => target };
        if (!animate || from == target) { glyphScale.ScaleX = glyphScale.ScaleY = target; return; }
        var resize = new DoubleAnimation(from, target, TimeSpan.FromSeconds(change == TaskProgressRing.Change.Appeared ? 0.25 : 0.3))
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        glyphScale.BeginAnimation(ScaleTransform.ScaleXProperty, resize);
        glyphScale.BeginAnimation(ScaleTransform.ScaleYProperty, resize);
    }
    internal void SetOpenAction(Action? action, string help, bool animate)
    { open = action; IsEnabled = action != null; Focusable = IsEnabled; AutomationProperties.SetHelpText(this, help); animations = animate; UpdateHover(); Ring.SetMotion(animate); }
    internal void SetAnimations(bool value) { animations = value; Ring.SetMotion(value); if (!value) UpdateHover(); }
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
        double rate = Text(state.RateText, state.RateSize, FontWeights.SemiBold) + Text(state.RateUnit + state.RateSeparator + row.TurnTime, 11, FontWeights.Medium);
        double model = Text(row.Model, 11, FontWeights.Medium) + Text(row.Effort, 11, FontWeights.Medium) + (row.Effort == null ? 0 : 4)
            + Text(row.Cost, 11, FontWeights.Medium) + (row.Cost == null ? 0 : row.PeakCost ? 16 : 7);
        double detail = Text(row.Status, 11, FontWeights.Medium) + (row.Subagents > 0 ? 24 + Text(row.SubagentText ?? "—", 11, FontWeights.Medium) : 0)
            + (row.Source == null ? 0 : 10 + Text(row.SourceLabel, 11, FontWeights.Medium) + (row.SourceKind == null ? 0 : 14));
        return 28 + 10 + 18 + Math.Max(Math.Min(200, Text(row.Title, 13, FontWeights.SemiBold)) + 16 + rate, detail + 16 + model);
    }
}

internal sealed class TaskRowState(EngineTaskRow value)
{
    public EngineTaskRow Value { get; } = value;
    public Brush ProviderInk => PacerPalette.Provider(Value.Provider);
    public Brush TitleInk => Value.Dimmed ? PacerPalette.Secondary : PacerPalette.Primary;
    public Brush DetailInk => Value.Attention != null || Value.Phase == "waitingForInput" ? PacerPalette.Attention
        : Value.Failed ? PacerPalette.Danger : PacerPalette.Secondary;
    public Brush StatusInk => Value.Attention != null || Value.Phase == "waitingForInput" ? PacerPalette.Attention
        : Value.Failed ? PacerPalette.Danger : Value.Dimmed ? PacerPalette.Secondary
        : Value.Phase == "interrupted" ? PacerPalette.Paused : Value.Phase is "running" or "completed" ? ProviderInk : PacerPalette.Secondary;
    public Brush RateInk => Value.RateIsFresh && !Value.Dimmed ? PacerPalette.Primary : PacerPalette.Secondary;
    public Brush DurationInk => Value.Phase == "running" ? PacerPalette.Ink(245, 245, 245, 199) : PacerPalette.Secondary;
    public string? RateText => Value.RateText ?? Value.RatePlaceholder;
    public int RateSize => Value.TokensPerSecond == null ? 11 : 13;
    public string RateUnit => Value.TokensPerSecond == null ? "" : " t/s";
    public string RateSeparator => Value.TurnTime != null && RateText != null ? " · " : "";
    public double ModelOpacity => Value.Dimmed ? 0.7 : 1;
    public Visibility SubagentsVisible => Visible(Value.Subagents > 0);
    public Visibility SourceVisible => Visible(Value.Source != null);
    public Visibility SourceIconVisible => Visible(Value.SourceKind != null);
    public Visibility CostVisible => Visible(Value.Cost != null);
    public Visibility PeakVisible => Visible(Value.PeakCost);
    public Visibility EffortVisible => Visible(Value.Effort != null);
    public string SourceSymbol => Value.SourceKind == "cloud" ? "cloud" : "server.rack";
    /// Inside the progress ring an ending glyph drops its own circle, as the
    /// Mac's StatusSymbols.enclosed does, so the ring is the only outline.
    public string GlyphSymbol => Value.ProgressState != null && Value.Symbol.EndsWith(".circle", StringComparison.Ordinal)
        ? Value.Symbol[..^".circle".Length] : Value.Symbol;
    public string AccessibleName => string.Join(", ", new[] { Value.Provider, Value.Title, Value.Status, Value.ProgressText, Value.Source,
        Value.Model, Value.Effort, RateText + RateUnit, Value.TurnTime, Value.Cost }.Where(s => !string.IsNullOrEmpty(s)));
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
}
