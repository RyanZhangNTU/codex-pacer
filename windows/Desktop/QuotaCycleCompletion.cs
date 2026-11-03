using System;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

// The next hold is ready only after the finite clocks have been removed.
internal sealed class QuotaCycleCompletion
{
    private event Action<long>? settled;
    internal int Subscribers => settled?.GetInvocationList().Length ?? 0;
    internal void Notify(long wake) => settled?.Invoke(wake);
    internal async Task AfterAsync(long baseline, TimeSpan timeout, CancellationToken cancellation = default)
    {
        if (timeout < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(timeout));
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed(long wake) { if (wake > baseline) completed.TrySetResult(); }
        settled += Changed;
        try { await completed.Task.WaitAsync(timeout, cancellation).ConfigureAwait(false); }
        finally { settled -= Changed; }
    }
}
