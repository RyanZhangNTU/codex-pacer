using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// Serializes complete newline-delimited commands on the engine's stdin pipe.
internal sealed class EngineCommandWriter(TimeSpan writeTimeout, CancellationToken lifetime, Action stopEngine)
{
    private readonly SemaphoreSlim writing = new(1, 1);
    private static readonly byte[] Newline = [(byte)'\n'];
    private bool failed;

    internal async Task WriteAsync(Stream input, byte[] json, CancellationToken caller)
    {
        await writing.WaitAsync(caller).ConfigureAwait(false);
        // A caller can stop waiting after any byte. Only the writer can release
        // the pipe for the next request, after this complete frame or a hard stop.
        Exception? error = await FinishAsync(input, json).WaitAsync(caller).ConfigureAwait(false);
        if (error != null) throw new IOException("The engine input could not accept a complete command.", error);
    }

    private async Task<Exception?> FinishAsync(Stream input, byte[] json)
    {
        try
        {
            if (failed) return new IOException("The engine input is closed.");
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
            budget.CancelAfter(writeTimeout);
            await input.WriteAsync(json, budget.Token).ConfigureAwait(false);
            await input.WriteAsync(Newline, budget.Token).ConfigureAwait(false);
            await input.FlushAsync(budget.Token).ConfigureAwait(false);
            return null;
        }
        catch (Exception error)
        {
            // A partially delivered command cannot safely be followed by another.
            // Every failure is caught: a caller that stopped waiting never observes this task.
            failed = true;
            stopEngine();
            return error;
        }
        finally { writing.Release(); }
    }
}
