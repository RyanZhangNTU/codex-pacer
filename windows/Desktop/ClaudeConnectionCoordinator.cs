using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// Owns only Claude's private profile. Cookie values are ephemeral input to the
/// original read-only quota client, never UI readings or persisted settings.
internal sealed class ClaudeConnectionCoordinator : IAsyncDisposable
{
    private readonly EngineClient engine;
    private readonly IClaudeWebSession session;
    private readonly Dispatcher dispatcher;
    private readonly bool bridgeEnabled;
    private readonly Func<Task<bool>> newSession;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Dictionary<string, CancellationTokenSource> reads = new();
    private readonly HashSet<string> cancelled = new();
    private readonly Queue<string> cancelledOrder = new();
    private readonly Dictionary<string, Task<bool>> connecting = new();
    private bool disposed, started, unsupported;
    private bool? availability;
    private Task? starting;
    internal string? LastFailure { get; private set; }
    internal bool IsOfflineDemo => !bridgeEnabled;
    internal bool Available => !disposed && started && (!bridgeEnabled || availability == true) && session.Available;
    internal ClaudeConnectionCoordinator(EngineClient engine, IClaudeWebSession session, Dispatcher dispatcher, bool bridgeEnabled = true, Func<Task<bool>>? newSession = null)
    {
        this.engine = engine; this.session = session; this.dispatcher = dispatcher; this.bridgeEnabled = bridgeEnabled;
        this.newSession = newSession ?? (() => Task.FromResult(true));
        engine.ClaudeHostRequest += Receive; engine.Status += EngineStatus;
    }
    internal async Task StartAsync()
    {
        if (starting != null) { await starting; return; }
        var pending = Start(); starting = pending;
        try { await pending; }
        finally { if (ReferenceEquals(starting, pending)) starting = null; }
    }
    private async Task Start()
    {
        if (disposed || unsupported) return;
        if (!bridgeEnabled) { started = true; return; }
        bool available = session.Available;
        // A profile that never signed in to Claude on the web has no cookies to
        // read: it starts no private browser until a sign-in creates the profile.
        if (available && availability != true && session.HasProfile)
        {
            try { await session.PrepareAsync(lifetime.Token); }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { return; }
            catch (Exception error) when (ProviderLoginWindow.Recoverable(error))
            { available = false; LastFailure = "windows.claude.connection_failed"; }
        }
        if (disposed || lifetime.IsCancellationRequested) return;
        started = true; if (availability == available) return;
        availability = available;
        try { await engine.SetClaudeWebHostAsync(available); }
        catch (EngineCommandException error) when (error.Code is "unknownMethod" or "unavailable") { started = false; unsupported = true; }
        catch { availability = null; throw; }
    }
    private void EngineStatus(string status)
    { if (!disposed && status is "engineStopped" or "engineProtocolFailed") lifetime.Cancel(); }
    private bool Current(string context) => !disposed && !engine.IsConnectionClosed && engine.LatestSnapshot?.ClaudeConnection?.Context == context;
    private bool CurrentCookieScope(string context) => Current(context) || !disposed && !engine.IsConnectionClosed &&
        engine.LatestSnapshot?.ClaudeCloudConnection is { Enabled: true, WebAvailable: true } cloud && cloud.Context == context;
    private void Receive(EngineHostRequest request)
    { if (!disposed && !dispatcher.HasShutdownStarted) _ = dispatcher.InvokeAsync(() => Handle(request)); }
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
        if (!Available || reads.Count >= 4 || !CurrentCookieScope(request.Context)) { _ = Reply(request, "offline", null); return; }
        if (!session.HasProfile) { _ = Reply(request, "signedOut", null); return; }
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); reads[request.RequestID] = cancellation;
        _ = Read(request, cancellation);
    }
    private async Task Read(EngineHostRequest request, CancellationTokenSource cancellation)
    {
        try
        {
            ClaudeWebSessionValue? value;
            try { value = await session.ReadAsync(cancellation.Token); }
            catch (Exception error) when (ProviderLoginWindow.Recoverable(error) && !cancellation.IsCancellationRequested)
            { if (CurrentCookieScope(request.Context)) await Reply(request, "offline", null); return; }
            if (!cancellation.IsCancellationRequested && CurrentCookieScope(request.Context)) await Reply(request, value == null ? "signedOut" : "ok", value);
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (reads.TryGetValue(request.RequestID, out var current) && ReferenceEquals(current, cancellation)) reads.Remove(request.RequestID);
            cancellation.Dispose();
        }
    }
    private async Task Reply(EngineHostRequest request, string state, ClaudeWebSessionValue? value)
    {
        if (disposed || engine.IsConnectionClosed) return;
        try
        {
            await engine.SendAsync("claudeWebResult", new { requestID = request.RequestID, context = request.Context, claudeSession = new {
                state, cookieHeader = value?.CookieHeader, sessionHash = value?.SessionHash, organizationID = value?.OrganizationID, userAgent = value?.UserAgent } });
        }
        catch (EngineCommandException error) when (error.Code == "commandLimit" && value != null)
        { await Reply(request, "invalid", null); }
        catch (EngineCommandException error) { if (error.Code != "staleWebReply") LastFailure = "windows.claude.connection_failed"; }
        catch (Exception error) when (error is IOException or OperationCanceledException) { }
    }
    internal async Task<bool> ConnectAsync(string context, bool switchAccount = false)
    {
        if (!Available || !Current(context)) return false;
        if (connecting.TryGetValue(context, out var existing)) return await existing;
        var task = Connect(context, switchAccount); connecting[context] = task;
        try { return await task; }
        finally { if (connecting.TryGetValue(context, out var current) && ReferenceEquals(current, task)) connecting.Remove(context); }
    }
    private async Task<bool> Connect(string context, bool switchAccount)
    {
        LastFailure = null;
        try
        {
            // Revoke quota/cloud reads before the profile can switch accounts.
            await engine.SendAsync("pauseClaudeConnection", new { context });
            context = engine.LatestSnapshot?.ClaudeConnection?.Context ?? "";
            if (!Current(context)) return false;
            if (switchAccount)
            {
                await session.ClearAsync(lifetime.Token);
            }
            bool signedIn = await session.SignInAsync();
            if (!Current(context)) return false;
            if (signedIn && session.SignInWasNew)
            {
                if (!await newSession()) throw new IOException("The new session preferences could not be saved.");
                context = engine.LatestSnapshot?.ClaudeConnection?.Context ?? "";
                if (!Current(context)) return false;
            }
            await engine.SendAsync("resetClaudeConnection", new { context }); return signedIn;
        }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
        { LastFailure = "windows.claude.connection_failed"; return false; }
    }
    internal async Task<bool> DisconnectAsync(string context)
    {
        if (!Current(context)) return false;
        LastFailure = null;
        try
        {
            await engine.SendAsync("pauseClaudeConnection", new { context });
            string current = engine.LatestSnapshot?.ClaudeConnection?.Context ?? "";
            await session.ClearAsync(lifetime.Token);
            if (!Current(current)) return false;
            await engine.SendAsync("resetClaudeConnection", new { context = current }); return true;
        }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
        { LastFailure = "windows.claude.disconnect_failed"; return false; }
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; engine.ClaudeHostRequest -= Receive; engine.Status -= EngineStatus;
        lifetime.Cancel(); foreach (var cancellation in reads.Values) cancellation.Cancel();
        await session.DisposeAsync(); lifetime.Dispose();
    }
}

internal sealed class OfflineClaudeWebSession : IClaudeWebSession
{
    public bool Available => false;
    public Task<ClaudeWebSessionValue?> ReadAsync(CancellationToken cancellation) => Task.FromResult<ClaudeWebSessionValue?>(null);
    public Task<bool> SignInAsync() => Task.FromResult(false);
    public Task ClearAsync(CancellationToken cancellation) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
