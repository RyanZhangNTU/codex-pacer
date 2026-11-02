using System;
using System.Collections.Generic;
using System.Windows.Media.Animation;
namespace CodexPacer.Windows;
// Finite WPF badge tracks; they do not depend on captured animation samples.
internal static class NativeBadgeCurves
{
    internal readonly record struct Frame(double Time, double Scale, double Opacity, bool Move = false);
    internal sealed record Track(double Duration, IReadOnlyList<Frame> Frames, Frame? AfterMove = null)
    {
        internal DoubleAnimationUsingKeyFrames Animation(bool opacity = false)
        {
            var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(Duration), FillBehavior = FillBehavior.HoldEnd };
            foreach (var frame in Frames)
            {
                double value = opacity ? frame.Opacity : frame.Scale;
                var time = KeyTime.FromTimeSpan(TimeSpan.FromTicks((long)Math.Round(frame.Time * TimeSpan.TicksPerSecond)));
                animation.KeyFrames.Add(frame.Move ? new DiscreteDoubleKeyFrame(value, time) : new LinearDoubleKeyFrame(value, time));
            }
            return animation;
        }
    }
    internal static Track Ripple { get; } = new(1.5, new Frame[] { new(0, 1, 1), new(.75, 1.8, 0), new(.7500001, 1, 1, true), new(1.5, 1.8, 0) });
    internal static Track Bloom { get; } = new(.48, new Frame[] { new(0, .72, 1), new(.24, 1.16, 1), new(.48, 1, 1) });
}
