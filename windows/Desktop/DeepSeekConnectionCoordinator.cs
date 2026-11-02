using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// Browser work remains on the UI thread; the child engine receives only
/// scoped numeric replies. Source changes revoke queued or in-flight reads.
internal sealed class DeepSeekConnectionCoordinator : IAsyncDisposable
{
    private readonly EngineClient engine;
    private readonly IDeepSeekWebSession session;
    private readonly Dispatcher dispatcher;
    private readonly bool bridgeEnabled;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Dictionary<string, CancellationTokenSource> reads = new();
    private readonly HashSet<string> cancelled = new();
    private readonly Queue<string> cancelledOrder = new();
    private readonly Dictionary<string, Task<bool>> connecting = new();
    private volatile bool disposed;
    private bool started;
    private bool unsupported;
    private bool? hostAvailability;
    internal string? LastFailure { get; private set; }
    internal bool IsOfflineDemo => !bridgeEnabled;
    internal bool Available => !disposed && started && session.Available;
    internal DeepSeekConnectionCoordinator(EngineClient engine, IDeepSeekWebSession session, Dispatcher dispatcher, bool bridgeEnabled = true)
    {
        this.engine = engine; this.session = session; this.dispatcher = dispatcher; this.bridgeEnabled = bridgeEnabled;
        engine.HostRequest += Receive; engine.Status += EngineStatus;
    }
    internal async Task StartAsync()
    {
        if (disposed || unsupported) return;
        started = true;
        if (!bridgeEnabled) return;
        bool available = session.Available;
        if (hostAvailability == available) return;
        hostAvailability = available;
        try { await engine.SetWebHostAsync(available); }
        catch (EngineCommandException error) when (error.Code is "unknownMethod" or "unavailable") { started = false; unsupported = true; }
        catch { hostAvailability = null; throw; }
    }
    private void EngineStatus(string status)
    {
        if (!disposed && (status is "engineStopped" or "engineProtocolFailed")) lifetime.Cancel();
    }
    private void Receive(EngineHostRequest request)
    {
        if (disposed || dispatcher.HasShutdownStarted) return;
        _ = dispatcher.InvokeAsync(() => Handle(request));
    }
    private void Handle(EngineHostRequest request)
    {
        if (disposed) return;
        if (request.Cancelled)
        {
            if (reads.TryGetValue(request.RequestID, out var active)) active.Cancel();
            if (cancelled.Add(request.RequestID)) cancelledOrder.Enqueue(request.RequestID);
            while (cancelledOrder.Count > 128) cancelled.Remove(cancelledOrder.Dequeue());
            return;
        }
        if (cancelled.Remove(request.RequestID) || reads.ContainsKey(request.RequestID)) return;
        if (!Available || reads.Count >= 4 || !Current(request.Context) || engine.LatestSnapshot?.DeepseekConnection?.Mode == "apiKey")
        { _ = Reply(request, new("offline")); return; }
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        reads[request.RequestID] = cancellation;
        _ = Read(request, cancellation);
    }
    private async Task Read(EngineHostRequest request, CancellationTokenSource cancellation)
    {
        try
        {
            DeepSeekWebReply result;
            try { result = await session.ReadAsync(cancellation.Token); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) && !cancellation.IsCancellationRequested) { result = new("offline"); }
            if (!disposed && !cancellation.IsCancellationRequested && Current(request.Context)) await Reply(request, result);
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (reads.TryGetValue(request.RequestID, out var current) && ReferenceEquals(current, cancellation)) reads.Remove(request.RequestID);
            cancellation.Dispose();
        }
    }
    private async Task Reply(EngineHostRequest request, DeepSeekWebReply reply)
    {
        if (disposed || engine.IsConnectionClosed) return;
        try { await engine.SendAsync("completeDeepSeekWebRead", new { webRequestID = request.RequestID, balanceContext = request.Context, webReply = reply }); }
        catch (EngineCommandException error) { if (error.Code != "staleSource") LastFailure = error.Code; }
        catch (Exception error) when (error is IOException or OperationCanceledException) { }
    }
    internal async Task<bool> ConnectAsync(string context)
    {
        if (!Available || !Current(context) || engine.LatestSnapshot?.DeepseekConnection?.Mode == "apiKey") return false;
        if (connecting.TryGetValue(context, out var existing)) return await existing;
        var task = Connect(context); connecting[context] = task;
        try { return await task; }
        finally { if (connecting.TryGetValue(context, out var current) && ReferenceEquals(current, task)) connecting.Remove(context); }
    }
    private async Task<bool> Connect(string context)
    {
        if (!await session.SignInAsync() || !Current(context) || engine.LatestSnapshot?.DeepseekConnection?.Mode == "apiKey") return false;
        try { await engine.SendAsync("deepSeekWebSessionChanged", new { balanceContext = context }); return true; }
        catch (EngineCommandException error) when (error.Code == "staleSource") { return false; }
    }
    private sealed record DisconnectScope(string Context);
    internal async Task DisconnectAsync(string context)
    {
        if (!Current(context)) throw new EngineCommandException("staleSource");
        var scope = await engine.QueryAsync<DisconnectScope>("beginDeepSeekDisconnect", new { balanceContext = context });
        bool success = false;
        try { await session.ClearAsync(lifetime.Token); success = true; }
        finally
        {
            if (Current(scope.Context))
                await engine.SendAsync("completeDeepSeekDisconnect", new { balanceContext = scope.Context, webSuccess = success });
        }
    }
    private bool Current(string context) => !disposed && !engine.IsConnectionClosed && engine.LatestSnapshot?.DeepseekConnection?.Context == context;
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; engine.HostRequest -= Receive; engine.Status -= EngineStatus;
        lifetime.Cancel(); foreach (var cancellation in reads.Values) cancellation.Cancel();
        await session.DisposeAsync(); lifetime.Dispose();
    }
}

/// Offline demo data never creates a production browser profile.
internal sealed class OfflineDeepSeekWebSession : IDeepSeekWebSession
{
    public bool Available => false;
    public Task<DeepSeekWebReply> ReadAsync(CancellationToken cancellation) => Task.FromResult(new DeepSeekWebReply("offline"));
    public Task<bool> SignInAsync() => Task.FromResult(false);
    public Task ClearAsync(CancellationToken cancellation) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
