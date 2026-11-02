using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

public sealed class ActivityBadge : Grid
{
    private readonly Border track = new() { BorderThickness = new Thickness(1.5), BorderBrush = PacerPalette.Ink(255, 255, 255, 26), CornerRadius = new CornerRadius(10) };
    private readonly Grid clipped = new();
    private readonly OrbitPaint paint = new();
    private readonly Border core = new() { Height = 15, MinWidth = 15, CornerRadius = new CornerRadius(7.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border ending = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), BorderBrush = PacerPalette.Ink(0, 0, 0, 217), BorderThickness = new Thickness(1.5),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -1, -1, 0) };
    private readonly RotateTransform rotation = new();
    private readonly ScaleTransform bloom = new(1, 1);
    private System.Windows.Shapes.Path? ripple;
    private bool blooming;
    internal (bool Ripple, bool Bloom, double Scale) TransientMotion => (ripple != null, blooming, bloom.ScaleX);
    private EngineHeader? previous;
    private bool rotating;
    private bool canAnimate = true;
    public ActivityBadge()
    {
        Width = Height = 20; IsHitTestVisible = false;
        RenderTransform = bloom; RenderTransformOrigin = new Point(0.5, 0.5);
        paint.HorizontalAlignment = HorizontalAlignment.Center; paint.VerticalAlignment = VerticalAlignment.Center;
        paint.RenderTransform = rotation; paint.RenderTransformOrigin = new Point(0.5, 0.5); paint.CacheMode = new BitmapCache(2);
        clipped.Children.Add(paint);
        Children.Add(track); Children.Add(clipped); Children.Add(core); Children.Add(ending);
        SizeChanged += (_, _) => UpdateClip();
        IsVisibleChanged += (_, _) => { UpdateRotation(); if (!IsVisible) StopTransient(); };
        Unloaded += (_, _) => { StopRotation(); StopTransient(); };
    }
    internal void Update(EngineHeader value, bool? animations = null)
    {
        Width = value.CoreSymbol == null && value.ActiveCount >= 10 ? 27 : 20;
        canAnimate = animations ?? SystemParameters.ClientAreaAnimation;
        bool reduce = !canAnimate;
        paint.Update(value.Orbit, !reduce);
        bool hasOrbit = value.Orbit.Values.Any(count => count > 0);
        track.Visibility = clipped.Visibility = hasOrbit ? Visibility.Visible : Visibility.Collapsed;
        Brush ink = value.Attention != null ? PacerPalette.Ink(66, 38, 5) : value.EndingIsCore ? EndingInk(value) : PacerPalette.Primary;
        if (value.CoreSymbol is string symbol)
            core.Child = new IconGlyph { Symbol = symbol.EndsWith(".circle", StringComparison.Ordinal) ? symbol[..^7] : symbol, Ink = ink, Width = 11, Height = 11,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        else if (value.ActiveCount > 0)
            core.Child = new TextBlock { Text = value.ActiveCountText ?? "—", FontSize = 10, FontWeight = FontWeights.Bold,
                Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        else core.Child = new Ellipse { Fill = PacerPalette.Tertiary, Width = 5, Height = 5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        core.Background = value.Attention != null ? PacerPalette.Attention : value.EndingIsCore ? WithAlpha(EndingInk(value), 51) : Brushes.Transparent;
        core.BorderBrush = value.EndingIsCore ? WithAlpha(EndingInk(value), 115) : Brushes.Transparent;
        core.BorderThickness = new Thickness(value.EndingIsCore ? 0.5 : 0);
        ending.Background = EndingInk(value);
        ending.Visibility = value.Ending != null && !value.EndingIsCore ? Visibility.Visible : Visibility.Collapsed;
        if (reduce) StopTransient();
        else if (IsVisible && previous != null)
        {
            if (previous.Attention == null && value.Attention != null) Pulse();
            if (previous.Ending == null && value.Ending != null) Bloom();
        }
        previous = value;
        UpdateClip(); UpdateRotation();
    }
    private static Brush EndingInk(EngineHeader value) => value.Ending == "xmark.circle" ? PacerPalette.Danger
        : value.Ending == "pause.circle" ? PacerPalette.Paused : PacerPalette.Provider(value.EndingProvider);
    private static Brush WithAlpha(Brush ink, byte alpha)
    {
        var color = ((SolidColorBrush)ink).Color;
        return PacerPalette.Ink(color.R, color.G, color.B, alpha);
    }
    private void UpdateClip()
    {
        double width = Width;
        var shape = new GeometryGroup { FillRule = FillRule.EvenOdd };
        shape.Children.Add(new RectangleGeometry(new Rect(0, 0, width, 20), 10, 10));
        shape.Children.Add(new RectangleGeometry(new Rect(1.5, 1.5, width - 3, 17), 8.5, 8.5));
        shape.Freeze(); clipped.Clip = shape;
        paint.Width = paint.Height = Math.Ceiling(Math.Sqrt(width * width + 400)) + 2;
    }
    private void UpdateRotation()
    {
        bool animate = IsVisible && canAnimate && previous?.Orbit.Values.Any(count => count > 0) == true;
        if (animate == rotating) return;
        if (!animate) { StopRotation(); return; }
        rotating = true;
        rotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.8)) { RepeatBehavior = RepeatBehavior.Forever });
    }
    private void StopRotation() { rotation.BeginAnimation(RotateTransform.AngleProperty, null); rotating = false; }
    private void Pulse()
    {
        StopRipple();
        var scale = new ScaleTransform(1, 1);
        var ring = new System.Windows.Shapes.Path { Width = Width - 5, Height = 15,
            Data = new RectangleGeometry(new Rect(0, 0, Width - 5, 15), 7.5, 7.5),
            Stroke = PacerPalette.Attention, StrokeThickness = 1.5, Opacity = 0,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            RenderTransform = scale, RenderTransformOrigin = new Point(0.5, 0.5), IsHitTestVisible = false };
        ripple = ring; Children.Add(ring);
        var fade = NativeBadgeCurves.Ripple.Animation(opacity: true);
        fade.Completed += (_, _) => { if (ReferenceEquals(ripple, ring)) StopRipple(); };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, NativeBadgeCurves.Ripple.Animation());
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, NativeBadgeCurves.Ripple.Animation());
        ring.BeginAnimation(OpacityProperty, fade);
    }
    private void Bloom()
    {
        blooming = true;
        var animation = NativeBadgeCurves.Bloom.Animation();
        animation.Completed += (_, _) => blooming = false;
        bloom.BeginAnimation(ScaleTransform.ScaleXProperty, animation);
        bloom.BeginAnimation(ScaleTransform.ScaleYProperty, NativeBadgeCurves.Bloom.Animation());
    }
    private void StopRipple()
    {
        if (ripple == null) return;
        ripple.BeginAnimation(OpacityProperty, null);
        if (ripple.RenderTransform is ScaleTransform scale)
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        }
        Children.Remove(ripple); ripple = null;
    }
    private void StopTransient()
    {
        StopRipple(); blooming = false;
        bloom.BeginAnimation(ScaleTransform.ScaleXProperty, null); bloom.BeginAnimation(ScaleTransform.ScaleYProperty, null);
    }
}

/// <summary>A cached conic gradient; rotation runs independently from stop changes.</summary>
internal sealed class OrbitPaint : FrameworkElement
{
    private readonly record struct Stop(double Position, Color Color);
    private static readonly DependencyProperty ProgressProperty = DependencyProperty.Register("Progress", typeof(double), typeof(OrbitPaint),
        new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));
    private Stop[] from = [], to = [];
    private IReadOnlyDictionary<string, int>? weights;
    private bool animated;
    internal void Update(IReadOnlyDictionary<string, int> values, bool animate)
    {
        if (weights != null && animated == animate && weights.Count == values.Count && weights.All(pair => values.TryGetValue(pair.Key, out int count) && count == pair.Value)) return;
        var shown = Current();
        var next = Stops(values, animate);
        bool ease = animated && animate && shown.Length == next.Length && shown.Length > 0;
        weights = values; animated = animate; from = shown; to = next;
        BeginAnimation(ProgressProperty, null);
        SetValue(ProgressProperty, 1.0);
        if (ease)
        {
            var change = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.35) };
            change.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            change.KeyFrames.Add(new SplineDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.35)), new KeySpline(0.42, 0, 0.58, 1)));
            BeginAnimation(ProgressProperty, change);
        }
        InvalidateVisual();
    }
    private Stop[] Current()
    {
        double progress = (double)GetValue(ProgressProperty);
        if (from.Length != to.Length || progress >= 1) return to;
        return to.Select((stop, index) => new Stop(from[index].Position + (stop.Position - from[index].Position) * progress,
            Mix(from[index].Color, stop.Color, progress))).ToArray();
    }
    private static Color Mix(Color a, Color b, double t) => Color.FromArgb(
        (byte)Math.Clamp(Math.Round(a.A + (b.A - a.A) * t), 0, 255), (byte)Math.Clamp(Math.Round(a.R + (b.R - a.R) * t), 0, 255),
        (byte)Math.Clamp(Math.Round(a.G + (b.G - a.G) * t), 0, 255), (byte)Math.Clamp(Math.Round(a.B + (b.B - a.B) * t), 0, 255));
    private static Stop[] Stops(IReadOnlyDictionary<string, int> weights, bool animate)
    {
        string[] providers = ["codex", "claude", "deepseek"];
        int Weight(string provider) => weights.TryGetValue(provider, out int count) ? Math.Max(0, count) : 0;
        int count = providers.Count(p => Weight(p) > 0), total = Math.Max(1, providers.Sum(Weight));
        double span = count > 1 ? 0.5 : 0.34, slot = 1.0 / Math.Max(1, count), last = 0;
        int rank = 0;
        var stops = new List<Stop>();
        foreach (string provider in providers)
        {
            var color = ((SolidColorBrush)PacerPalette.Provider(provider)).Color;
            var clear = Color.FromArgb(0, color.R, color.G, color.B);
            int weight = Weight(provider);
            if (!animate)
            {
                if (weight == 0) continue;
                color.A = 191; stops.Add(new(last, color)); last += (double)weight / total; stops.Add(new(last, color)); continue;
            }
            if (weight == 0) { for (int index = 0; index < 3; index++) stops.Add(new(last, clear)); continue; }
            double head = rank * slot, tail = head + Math.Min(span * weight / total, slot * 0.9);
            rank++; last = tail;
            stops.Add(new(head, clear)); stops.Add(new(head, color)); stops.Add(new(tail, clear));
        }
        return stops.ToArray();
    }
    protected override void OnRender(DrawingContext drawing)
    {
        Stop[] stops = Current();
        if (stops.Length == 0) return;
        Color At(double fraction)
        {
            int index = 0;
            while (index + 1 < stops.Length && stops[index + 1].Position <= fraction) index++;
            if (index + 1 == stops.Length) return stops[index].Color;
            double span = stops[index + 1].Position - stops[index].Position;
            return Mix(stops[index].Color, stops[index + 1].Color, span <= 0 ? 1 : Math.Clamp((fraction - stops[index].Position) / span, 0, 1));
        }
        var centre = new Point(ActualWidth / 2, ActualHeight / 2);
        double radius = Math.Max(ActualWidth, ActualHeight);
        Point Point(double fraction) => new(centre.X + radius * Math.Cos((-90 - fraction * 360) * Math.PI / 180),
            centre.Y + radius * Math.Sin((-90 - fraction * 360) * Math.PI / 180));
        for (int step = 0; step < 360; step++)
        {
            Color color = At((step + 0.5) / 360);
            if (color.A == 0) continue;
            var path = new StreamGeometry();
            using (var geometry = path.Open()) { geometry.BeginFigure(centre, true, true); geometry.LineTo(Point(step / 360.0), true, false); geometry.LineTo(Point((step + 1.02) / 360.0), true, false); }
            path.Freeze();
            var ink = new SolidColorBrush(color); ink.Freeze(); drawing.DrawGeometry(ink, null, path);
        }
    }
}
