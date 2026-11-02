using System;
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
        Console.WriteLine("PASS task-row timing: WPF clock follows the shared Swift curve at all 121 samples");
    }
}
