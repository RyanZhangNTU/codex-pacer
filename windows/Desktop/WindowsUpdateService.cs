using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record WindowsUpdateStatus(bool Available, bool Busy, string MessageKey);

internal sealed class WindowsUpdateService : IAsyncDisposable
{
    internal static readonly TimeSpan AutomaticInterval = TimeSpan.FromDays(1);
    private readonly IWindowsUpdateBackend? backend;
    private readonly UpdateFeedProxy? proxy;
    private readonly WindowsUpdateState? state;
    private readonly Func<DateTimeOffset> now;
    private readonly Action<Action> post;
    private readonly TimeSpan requestTimeout;
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource notesLifetime = new();
    private CancellationTokenSource? autoWake;
    private volatile bool disposed, installing, expired, operationActive;
    private bool faulted, automatic, interactive;
    private DateTimeOffset lastCheck = DateTimeOffset.MinValue;
    private Uri? operationFeed;
    private long generation;
    internal WindowsUpdateStatus Status { get; private set; } = new(false, false, "windows.updates.unconfigured");
    internal event Action<WindowsUpdateStatus>? Changed;
    internal WindowsUpdateService(Action<Action> post, IWindowsUpdateBackend? backend = null, UpdateFeedProxy? proxy = null,
        TimeSpan? requestTimeout = null, WindowsUpdateState? state = null, Func<DateTimeOffset>? now = null)
    {
        this.post = post; this.backend = backend; this.proxy = proxy; this.state = state; this.now = now ?? (() => DateTimeOffset.UtcNow);
        this.requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(3);
        if (backend != null) backend.Changed += OnBackend;
        if (proxy != null) { proxy.Expired += OnExpired; proxy.Failed += OnProxyFailed; }
    }
    private void Publish(WindowsUpdateStatus value) => post(() => { if (disposed) return; Status = value; Changed?.Invoke(value); });
    internal async Task InitializeAsync(WindowsUpdateChannel channel, string version, string build, string language, bool automatic,
        WindowsInstallationIdentity identity, Action installStarted)
    {
        if (backend == null || proxy == null || disposed) return;
        backend.Install = path =>
        {
            if (disposed || installing || !operationActive || expired) return false;
            var prepared = UpdateHandoff.Prepare(path, proxy, channel, identity, Path.Combine(identity.Root, "Maintenance", "PacerMaintenance.exe"));
            UpdateHandoff.Start(prepared); installing = true; operationActive = false;
            _ = proxy.StopOperationAsync(operationFeed); post(installStarted); return true;
        };
        try
        {
            this.automatic = automatic;
            await Task.Run(() =>
            {
                if (state?.Read("PacerLastCheckUtc") is string saved && long.TryParse(saved, NumberStyles.Integer, CultureInfo.InvariantCulture, out long seconds))
                    lastCheck = DateTimeOffset.FromUnixTimeSeconds(seconds);
                backend.Initialize(proxy.Feed, channel.PublicKey, version, build, language, automatic);
            }).WaitAsync(TimeSpan.FromSeconds(10));
            Publish(new(true, false, "updates.policy")); ArmAutomatic();
        }
        catch (Exception error) when (Recoverable(error)) { faulted = true; Publish(new(false, false, "windows.updates.failed")); }
    }
    internal async Task<string?> ReadReleaseNotesAsync()
    {
        if (disposed || faulted || installing || proxy == null || !Status.Available || Status.Busy) return null;
        string? notes = await proxy.ReadReleaseNotesAsync(notesLifetime.Token);
        return disposed ? null : notes;
    }
    internal Task<bool> CheckAsync() => BeginOperation(interactive: true);
    internal Task<bool> CheckAutomaticIfDueAsync() => automatic && now() - lastCheck >= AutomaticInterval
        ? BeginOperation(interactive: false) : Task.FromResult(false);
    private async Task<bool> BeginOperation(bool interactive, bool restartExpired = false)
    {
        if (backend == null || proxy == null || disposed || installing || faulted || !Status.Available ||
            !restartExpired && (Status.Busy || operationActive) || !await operations.WaitAsync(0)) return false;
        try
        {
            this.interactive = interactive; expired = false; operationActive = true;
            long context = Interlocked.Increment(ref generation);
            operationFeed = null;
            autoWake?.Cancel(); lastCheck = now();
            Publish(Status with { Busy = interactive, MessageKey = interactive ? "updates.checking" : "updates.policy" });
            Uri feed = await proxy.StartOperationAsync().WaitAsync(requestTimeout);
            operationFeed = feed;
            await Task.Run(() =>
            {
                state?.Write("PacerLastCheckUtc", lastCheck.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
                backend.Check(feed, interactive, context);
            }).WaitAsync(requestTimeout);
            return true;
        }
        catch (Exception error) when (Recoverable(error))
        {
            faulted = error is TimeoutException; operationActive = false;
            try { await proxy.StopOperationAsync(operationFeed).WaitAsync(requestTimeout); } catch (Exception failure) when (Recoverable(failure)) { }
            Publish(new(!faulted, false, "windows.updates.failed")); ArmAutomatic(); return false;
        }
        finally { operations.Release(); }
    }
    private void ArmAutomatic()
    {
        autoWake?.Cancel(); autoWake?.Dispose(); autoWake = null;
        if (disposed || faulted || !automatic || state == null || operationActive || Status.Busy) return;
        var wake = new CancellationTokenSource(); autoWake = wake;
        TimeSpan delay = AutomaticInterval - (now() - lastCheck);
        if (delay < TimeSpan.FromSeconds(1)) delay = TimeSpan.FromSeconds(1);
        _ = WakeAutomatic(delay, wake.Token);
    }
    private async Task WakeAutomatic(TimeSpan delay, CancellationToken cancellation)
    {
        try { await Task.Delay(delay, cancellation); if (!cancellation.IsCancellationRequested) post(() => { if (!cancellation.IsCancellationRequested) _ = CheckAutomaticIfDueAsync(); }); }
        catch (OperationCanceledException) { }
    }
    internal async Task<bool> SetAutomaticAsync(bool value)
    {
        if (backend == null || disposed || !Status.Available || !await operations.WaitAsync(0)) return false;
        try { await Task.Run(() => backend.SetAutomatic(value)).WaitAsync(requestTimeout); automatic = value; ArmAutomatic(); return true; }
        catch (Exception error) when (Recoverable(error)) { faulted = error is TimeoutException; Publish(Status with { Available = !faulted, MessageKey = "windows.updates.failed" }); return false; }
        finally { operations.Release(); }
    }
    internal async Task<bool> ApplyAutomaticAsync(bool value, PreferencesSession preferences)
    {
        bool previous = preferences.Current.AutomaticUpdates;
        if (!await SetAutomaticAsync(value)) { _ = await SetAutomaticAsync(previous); return false; }
        if (await preferences.ChangeAsync(current => current with { AutomaticUpdates = value }) == PreferencesApplyResult.Applied) return true;
        _ = await SetAutomaticAsync(previous); return false;
    }
    private void OnExpired(Uri feed) => post(() =>
    {
        if (disposed || !operationActive || operationFeed != feed) return;
        expired = true; operationActive = false;
        Status = Status with { MessageKey = "windows.updates.expired" }; Changed?.Invoke(Status);
        // The old WinSparkle window can still be waiting for confirmation. If
        // Download is selected, its closed endpoint fails and triggers a fresh
        // owned check, with a new port/token, rather than using stale metadata.
    });
    private void OnProxyFailed(Uri feed) => post(() =>
    {
        if (operationFeed == feed) OnBackend(UpdateBackendEvent.Failed, Interlocked.Read(ref generation));
    });
    private void OnBackend(UpdateBackendEvent value, long context) => post(() =>
    {
        if (disposed || installing || faulted || context != Interlocked.Read(ref generation)) return;
        if (expired && value == UpdateBackendEvent.Failed) { _ = BeginOperation(interactive: true, restartExpired: true); return; }
        if (value == UpdateBackendEvent.Found)
        { if (operationActive && !expired) { Status = new(true, true, "windows.updates.available"); Changed?.Invoke(Status); } return; }
        operationActive = false; expired = false;
        if (proxy != null) _ = proxy.StopOperationAsync(operationFeed);
        Status = value switch
        {
            UpdateBackendEvent.NoUpdate => Status with { Busy = interactive, MessageKey = "updates.no_update" },
            UpdateBackendEvent.Failed => Status with { Busy = interactive, MessageKey = "windows.updates.failed" },
            _ => Status with { Busy = false, MessageKey = Status.MessageKey is "updates.checking" or "windows.updates.available" or "windows.updates.expired" ? "updates.cancelled" : Status.MessageKey }
        };
        Changed?.Invoke(Status); ArmAutomatic();
    });
    internal static bool Recoverable(Exception error) => error is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException
        or ArgumentException or System.ComponentModel.Win32Exception or TimeoutException or OperationCanceledException or System.Text.Json.JsonException
        or System.Security.Cryptography.CryptographicException or EntryPointNotFoundException or BadImageFormatException;
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; autoWake?.Cancel(); autoWake?.Dispose(); notesLifetime.Cancel();
        if (proxy != null)
        {
            proxy.Expired -= OnExpired; proxy.Failed -= OnProxyFailed;
            try { await proxy.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3)); }
            catch (Exception error) when (Recoverable(error)) { }
        }
        if (backend != null)
        {
            backend.Changed -= OnBackend; backend.Install = null;
            var cleanup = Task.Run(backend.Dispose);
            try { await cleanup.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (Exception error) when (Recoverable(error)) { }
        }
    }
}
