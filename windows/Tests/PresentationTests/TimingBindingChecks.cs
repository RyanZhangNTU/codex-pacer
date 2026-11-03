using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using CodexPacer.Windows;

internal static class TimingBindingChecks
{
    internal static void Run()
    {
        var timing = NativeTaskRowTiming.Shared;
        var animation = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(timing.Duration)) { EasingFunction = timing.Ease };
        var clock = (AnimationClock)animation.CreateClock(true);
        var controller = clock.Controller!;
        controller.Begin();
        for (int step = 0; step <= 120; step++)
        {
            controller.SeekAlignedToLastTick(TimeSpan.FromTicks((long)Math.Round(timing.Duration * step / 120 * TimeSpan.TicksPerSecond)), TimeSeekOrigin.BeginTime);
            if (Math.Abs(animation.GetCurrentValue(0, 1, clock) - timing.Value(step / 120.0)) > .00001)
                throw new InvalidOperationException("The task-row WPF clock must consume the shared Swift curve.");
        }
        controller.Stop();
        CheckFiniteLease(timing);
        Console.WriteLine("PASS task-row timing: WPF clock follows the shared Swift curve at all 121 samples");
    }
    private static void CheckFiniteLease(NativeTaskRowTiming timing)
    {
        void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var value = new Border { Opacity = 1 };
        AnimationClock? current = null;
        void Apply(AnimationClock? next) { current = next; value.ApplyAnimationClock(UIElement.OpacityProperty, next); }
        var duration = TimeSpan.FromMilliseconds(200);
        using var forward = new AnimationLease(new DoubleAnimation(.3, 1, duration)
            { EasingFunction = timing.Ease, FillBehavior = FillBehavior.Stop }, Apply);
        var clock = current!; clock.Controller!.Begin();
        clock.Controller.SeekAlignedToLastTick(TimeSpan.Zero, TimeSeekOrigin.BeginTime);
        Check(Math.Abs(value.Opacity - .3) < .00001, "A finite opacity clock starts at the displayed value, including its first timing tick");
        for (int sample = 1; sample < 120; sample++)
        {
            double progress = sample / 120.0;
            clock.Controller.SeekAlignedToLastTick(TimeSpan.FromTicks((long)Math.Round(duration.Ticks * progress)), TimeSeekOrigin.BeginTime);
            Check(Math.Abs(value.Opacity - (.3 + .7 * timing.Value(progress))) < .00001,
                "Finite opacity progress uses the original easing before completion");
        }
        clock.Controller.SeekAlignedToLastTick(TimeSpan.FromTicks(duration.Ticks / 2), TimeSeekOrigin.BeginTime);
        double displayed = value.Opacity;
        Check(displayed > .3 && displayed < 1, "The finite fade has real intermediate values");
        forward.Dispose(); value.Opacity = .3;
        using var reverse = new AnimationLease(new DoubleAnimation(displayed, .3, duration)
            { EasingFunction = timing.Ease, FillBehavior = FillBehavior.Stop }, Apply);
        clock = current!; clock.Controller!.Begin();
        clock.Controller.SeekAlignedToLastTick(TimeSpan.Zero, TimeSeekOrigin.BeginTime);
        Check(Math.Abs(value.Opacity - displayed) < .00001, "A reversed lease starts without an opacity jump");
        clock.Controller.SeekAlignedToLastTick(TimeSpan.FromTicks(duration.Ticks / 2), TimeSeekOrigin.BeginTime);
        Check(value.Opacity > .3 && value.Opacity < displayed, "Reversal eases back from the displayed opacity");
        clock.Controller.SeekAlignedToLastTick(duration, TimeSeekOrigin.BeginTime);
        Check(Math.Abs(value.Opacity - .3) < .00001, "A completed finite fade restores its target base value");
        reverse.Dispose();
        Check(current == null && !value.HasAnimatedProperties && Math.Abs(value.Opacity - .3) < .00001,
            "Disposal releases the property clock while retaining the settled value");
        Console.WriteLine("PASS finite animation lease: first tick, 119 intermediate samples, reversal, completion and clock removal");
    }
}
