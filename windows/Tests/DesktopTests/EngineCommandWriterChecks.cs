using System.Text;
using System.Text.Json;
using CodexPacer.Windows;

internal static class EngineCommandWriterChecks
{
    internal static async Task Run()
    {
        var limit = TimeSpan.FromSeconds(5);
        bool stopped = false;
        var writer = new EngineCommandWriter(limit, CancellationToken.None, () => stopped = true);
        using var pipe = new PausedPipe();
        using var caller = new CancellationTokenSource();
        Task first = writer.WriteAsync(pipe, "{\"id\":1}"u8.ToArray(), caller.Token);
        await pipe.Partial.Task.WaitAsync(limit);
        caller.Cancel();
        try { await first.WaitAsync(limit); throw new InvalidOperationException("The caller did not observe its deadline."); }
        catch (OperationCanceledException) { }

        using var queued = new CancellationTokenSource();
        Task abandoned = writer.WriteAsync(pipe, "{\"id\":2}"u8.ToArray(), queued.Token);
        queued.Cancel();
        try { await abandoned.WaitAsync(limit); throw new InvalidOperationException("The queued command was sent."); }
        catch (OperationCanceledException) { }

        Task next = writer.WriteAsync(pipe, "{\"id\":3}"u8.ToArray(), CancellationToken.None);
        if (next.IsCompleted) throw new InvalidOperationException("A request overtook a partially written frame.");
        pipe.Resume.SetResult();
        await next.WaitAsync(limit);
        string[] lines = Encoding.UTF8.GetString(pipe.ToArray()).Split('\n');
        if (lines.Length != 3 || lines[2].Length != 0 || stopped) throw new InvalidDataException("Expected two complete commands on the original connection.");
        using var one = JsonDocument.Parse(lines[0]);
        using var three = JsonDocument.Parse(lines[1]);
        if (one.RootElement.GetProperty("id").GetInt32() != 1 || three.RootElement.GetProperty("id").GetInt32() != 3)
            throw new InvalidDataException("The abandoned caller corrupted the next request.");

        using var stalled = new PausedPipe();
        using var lifetime = new CancellationTokenSource();
        writer = new EngineCommandWriter(limit, lifetime.Token, () => stopped = true);
        Task broken = writer.WriteAsync(stalled, "{}"u8.ToArray(), CancellationToken.None);
        await stalled.Partial.Task.WaitAsync(limit);
        lifetime.Cancel();
        try { await broken.WaitAsync(limit); throw new InvalidOperationException("A broken transport reported success."); }
        catch (IOException) { }
        long size = stalled.Length;
        try { await writer.WriteAsync(stalled, "{}"u8.ToArray(), CancellationToken.None); throw new InvalidOperationException("A broken pipe accepted a new command."); }
        catch (IOException) { }
        if (!stopped || size != stalled.Length) throw new InvalidOperationException("A partial transport failure must close the connection.");
    }

    private sealed class PausedPipe : MemoryStream
    {
        internal readonly TaskCompletionSource Partial = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Resume = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken token = default)
        {
            if (!Partial.Task.IsCompleted)
            {
                Write(data.Span[..1]);
                Partial.SetResult();
                await Resume.Task.WaitAsync(token);
                data = data[1..];
            }
            await base.WriteAsync(data, token);
        }
    }
}
