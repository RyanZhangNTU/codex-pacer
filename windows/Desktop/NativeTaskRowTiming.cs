using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

internal sealed class NativeTaskRowTiming
{
    private static readonly Lazy<NativeTaskRowTiming> SharedValue = new(() => new(Path.Combine(AppContext.BaseDirectory, "Engine")));
    internal static NativeTaskRowTiming Shared => SharedValue.Value;
    private readonly Sample sample;
    internal double Duration { get; }
    internal double NavigationErrorDuration { get; }
    internal EasingFunctionBase Ease { get; }
    private NativeTaskRowTiming(string directory)
    {
        sample = NativeMotion.SharedExport<Sample>(directory, "pacer_task_row_hover_value");
        Duration = NativeMotion.SharedExport<DurationValue>(directory, "pacer_task_row_hover_duration")();
        NavigationErrorDuration = NativeMotion.SharedExport<DurationValue>(directory, "pacer_task_navigation_error_duration")();
        if (!double.IsFinite(Duration) || Duration <= 0 || Duration > 1) throw new InvalidDataException("The shared row timing is incompatible.");
        if (!double.IsFinite(NavigationErrorDuration) || NavigationErrorDuration <= 0 || NavigationErrorDuration > 300)
            throw new InvalidDataException("The shared navigation error duration is incompatible.");
        Ease = new Curve(this) { EasingMode = EasingMode.EaseIn };
    }
    internal double Value(double fraction) => sample(fraction);
    private sealed class Curve(NativeTaskRowTiming timing) : EasingFunctionBase
    {
        protected override double EaseInCore(double normalizedTime) => timing.Value(normalizedTime);
        protected override Freezable CreateInstanceCore() => new Curve(timing) { EasingMode = EasingMode.EaseIn };
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate double Sample(double fraction);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate double DurationValue();
}
