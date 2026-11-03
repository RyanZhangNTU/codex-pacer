using System;
using System.Threading;
using System.Threading.Tasks;
using CodexPacer.Windows;

internal static class QuotaCycleCompletionChecks
{
    internal static async Task Run()
    {
        var signal = new QuotaCycleCompletion();
        var wait = signal.AfterAsync(4, TimeSpan.FromMilliseconds(3400));
        Check(!wait.IsCompleted && signal.Subscribers == 1, "A pending clock must keep the next-cycle wait pending");
        signal.Notify(3); signal.Notify(4);
        Check(!wait.IsCompleted, "Old and repeated hold events cannot complete the next cycle");
        signal.Notify(5); signal.Notify(5); await wait;
        Check(signal.Subscribers == 0, "The matching completion releases its subscription exactly once");
        var next = signal.AfterAsync(5, TimeSpan.FromMilliseconds(3400));
        signal.Notify(5); Check(!next.IsCompleted, "A completed cycle cannot satisfy a later wait");
        signal.Notify(6); await next;
        Check(signal.Subscribers == 0, "Repeated cycle waits leave no observers");
        bool timeout = false;
        try { await signal.AfterAsync(6, TimeSpan.Zero); } catch (TimeoutException) { timeout = true; }
        Check(timeout && signal.Subscribers == 0, "An expired deadline fails and detaches without a polling sleep");
        using var cancelled = new CancellationTokenSource();
        var stopping = signal.AfterAsync(6, TimeSpan.FromMilliseconds(3400), cancelled.Token); cancelled.Cancel();
        bool cancellation = false;
        try { await stopping; } catch (OperationCanceledException) { cancellation = true; }
        Check(cancellation && signal.Subscribers == 0, "Cancellation removes the pending observer");
        bool infinite = false;
        try { await signal.AfterAsync(6, Timeout.InfiniteTimeSpan); } catch (ArgumentOutOfRangeException) { infinite = true; }
        Check(infinite && signal.Subscribers == 0, "The completion path rejects unbounded deadlines");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
