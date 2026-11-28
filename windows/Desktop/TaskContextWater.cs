using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

public sealed partial class TaskStatusIcon
{
    private sealed record FaceMemory(string Face, double Seen, WeakReference<TaskStatusIcon> Owner, LevelSweep? Level, double? ReleasedHeight);
    internal sealed record LevelSweep(double From, double To, double Start, double Duration)
    {
        internal double Displayed(double now)
        {
            if (Duration == 0) return To;
            double t = Math.Clamp((now - Start) / Duration, 0, 1);
            return From + (To - From) * t * t * (3 - 2 * t);
        }
    }

    // Height is a share of the diameter. Invert the circular segment's area below the chord.
    internal static double LevelHeight(double fraction)
    {
        if (fraction <= 0) return 0;
        if (fraction >= 1) return 1;
        double low = -1, high = 1;
        for (int i = 0; i < 24; i++)
        {
            double x = (low + high) / 2;
            if (Math.Acos(x) - x * Math.Sqrt(1 - x * x) > Math.PI * fraction) low = x; else high = x;
        }
        return (1 - (low + high) / 2) / 2;
    }

    private static readonly double LineCutoff = LevelHeight(0.99);
    private static readonly KeySpline SmoothStep = new(1.0 / 3, 0, 2.0 / 3, 1);
    private static readonly DependencyProperty LevelProperty = DependencyProperty.Register("Level", typeof(double), typeof(TaskStatusIcon),
        new PropertyMetadata(0.0, (owner, _) => ((TaskStatusIcon)owner).DrawWater()));
    private static readonly DependencyProperty PressProperty = DependencyProperty.Register("Press", typeof(double), typeof(TaskStatusIcon),
        new PropertyMetadata(0.0, (owner, _) => ((TaskStatusIcon)owner).DrawPress()));

    private AnimationLease? levelLease, pressLease;
    private double? compactingSince, pressingSince;
    private LinearGradientBrush? water;
    private RectangleGeometry? airClip, paintClip;
    private Color waterColor;
    private double Press => (double)GetValue(PressProperty);
    internal double LevelHeightShown => (double)GetValue(LevelProperty) * (1 - 0.05 * Press);
    internal bool ShowsLevel => water != null || airClip != null;
    internal bool Pressing => pressLease != null;
    internal bool LevelMoving => levelLease != null;
    internal LevelSweep? Sweep { get; private set; }

    private void ApplyLevel(string face, double? fraction, double? fillEnd, double? released, FaceMemory? previous, double now)
    {
        bool solid = face.StartsWith("solid:", StringComparison.Ordinal);
        LevelSweep? sweep = null;
        if (fraction is double area)
        {
            double target = LevelHeight(area);
            if (motion && fillEnd is double end) sweep = new(1, target, end, 0.5);
            else if (motion && IsOrb(face) && released is double height) sweep = new(height, target, now, 0.9);
            else if (motion && previous?.Level is { } last && previous.Face.StartsWith("solid:", StringComparison.Ordinal) == solid)
                sweep = last.To == target ? last : new(last.Displayed(now), target, now, 0.5);
            else sweep = new(target, target, now, 0);
            released = null;
            if (solid)
            {
                water = null;
                airClip ??= new RectangleGeometry(); paintClip ??= new RectangleGeometry();
                bool read = face.EndsWith(":read", StringComparison.Ordinal);
                discAir.Fill = read ? PacerPalette.Overlay(20) : new SolidColorBrush(Alpha(color, 0.42));
                discAir.Clip = airClip; discFill.Clip = discSheen.Clip = paintClip;
                if (read) discFill.Fill = PacerPalette.Overlay(54);
            }
            else
            {
                ClearDiscWater();
                if (water == null || waterColor != color)
                {
                    waterColor = color;
                    water = new LinearGradientBrush(new GradientStopCollection {
                        new(Alpha(color, 0.22), 0), new(Alpha(color, 0.40), 0), new(Alpha(color, 0.85), 0),
                        new(Alpha(color, 0.85), 0), new(Alpha(color, 0.06), 0), new(Alpha(color, 0.06), 1)
                    }, new Point(0.5, 1), new Point(0.5, 0));
                }
                orb.Fill = water;
            }
            DrawLevel(sweep, now);
        }
        else
        {
            levelLease?.Dispose(); levelLease = null;
            if (water != null && IsOrb(face)) orb.Fill = OrbFill();
            if (airClip != null && solid && face.EndsWith(":read", StringComparison.Ordinal)) discFill.Fill = new SolidColorBrush(ReadDisc);
            ClearDiscWater(); water = null;
            if (!IsOrb(face)) released = null;
        }
        Sweep = sweep;
        Faces[id!] = new(face, now, new(this), sweep, released);
        Prune(now);
    }

    private void ClearDiscWater()
    {
        if (airClip == null) return;
        discAir.Fill = null; discAir.Clip = discFill.Clip = discSheen.Clip = null;
        airClip = paintClip = null;
    }
    private void DrawLevel(LevelSweep next, double now)
    {
        if (next != Sweep || levelLease == null)
        {
            levelLease?.Dispose(); levelLease = null;
            if (next.Duration == 0 || now >= next.Start + next.Duration) SetValue(LevelProperty, next.To);
            else
            {
                double delay = Math.Max(0, next.Start - now);
                var animation = Held(next.From, next.To, next.Duration, delay,
                    new SplineDoubleKeyFrame(next.To, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(delay + next.Duration)), SmoothStep));
                SetValue(LevelProperty, next.From);
                levelLease = new AnimationLease(animation, clock => ApplyAnimationClock(LevelProperty, clock),
                    () => { levelLease = null; SetValue(LevelProperty, next.To); });
                if (now > next.Start) levelLease.Seek(TimeSpan.FromSeconds(now - next.Start));
            }
        }
        DrawWater();
    }

    private static Color Alpha(Color ink, double alpha) => Color.FromArgb((byte)Math.Round(255 * alpha), ink.R, ink.G, ink.B);
    private void DrawWater()
    {
        double height = (double)GetValue(LevelProperty);
        if (water != null)
        {
            // Press the water about the bottom. The air above it always covers the orb.
            double scale = 1 - 0.05 * Press, edge = height * scale;
            double line = height > 0 && height < LineCutoff ? 0.7 / OrbSide * scale : 0;
            var stops = water.GradientStops;
            stops[1].Offset = stops[2].Offset = edge;
            stops[3].Offset = stops[4].Offset = Math.Min(1, edge + line);
            stops[1].Color = Alpha(waterColor, 0.40 + 0.12 * Press);
        }
        if (airClip != null && paintClip != null)
        {
            double y = (1 - height) * DiscSide;
            airClip.Rect = new Rect(0, 0, DiscSide, y);
            paintClip.Rect = new Rect(0, y, DiscSide, DiscSide - y);
        }
    }

    private void StopLevel()
    {
        levelLease?.Dispose(); levelLease = null;
        if (Sweep != null) SetValue(LevelProperty, Sweep.To);
    }

    private void SettleLevel()
    {
        StopLevel();
        if (Sweep is not { Duration: > 0 } last) return;
        Sweep = new(last.To, last.To, TaskProgressRing.Now, 0);
        if (id != null && Faces.TryGetValue(id, out var memory) && memory.Owner.TryGetTarget(out var owner) && owner == this)
            Faces[id] = memory with { Level = Sweep };
    }

    private void RefreshPress()
    {
        if (!motion || !IsVisible || faceKey != Compacting || compactingSince is not double since)
        {
            StopPress();
            return;
        }
        if (pressingSince == since && pressLease != null) { DrawPress(); return; }
        StopPress();
        pressingSince = since;
        const double period = 2.4;
        double age = Math.Max(0, (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds - since);
        var loop = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(period / 2)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(-(age % period)), EasingFunction = new SplineEase(new KeySpline(0.445, 0.05, 0.55, 0.95)) };
        Timeline.SetDesiredFrameRate(loop, 30);
        pressLease = new AnimationLease(loop, clock => ApplyAnimationClock(PressProperty, clock));
    }
    private void DrawPress()
    {
        DrawWater();
        if (faceKey != Compacting || parts.Count != 3) return;
        for (int i = 1; i <= 2; i++)
            if (parts[i].Part.RenderTransform is TransformGroup transforms && transforms.Children[1] is TranslateTransform offset)
                offset.Y = (i == 1 ? 1.3 : -1.3) * Press;
    }
    private void StopPress()
    {
        pressLease?.Dispose(); pressLease = null; pressingSince = null;
    }
}
