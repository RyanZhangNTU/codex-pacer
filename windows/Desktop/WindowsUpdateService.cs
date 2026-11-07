using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record WindowsUpdateStatus(bool Available, bool Busy, string MessageKey);

/// The update window, kept separate so the service has no WPF dependency.
internal interface IWindowsUpdatePresenter
{
    void Checking();
    void Offer(WindowsUpdatePackage package, bool manual);
    void UpToDate();
    // Only a manual check reports a failure; automatic checks fail quietly.
    void Failed();
}

internal sealed class WindowsUpdateService : IAsyncDisposable
{
    internal static readonly TimeSpan AutomaticInterval = TimeSpan.FromDays(1);
    /// An offer older than this is verified again before its download starts.
    internal static readonly TimeSpan OfferLifetime = TimeSpan.FromMinutes(30);
    internal const string SkipKey = "SkipThisVersion", AutomaticKey = "PacerAutomaticChecks", LastCheckKey = "PacerLastCheckUtc",
        PatchFailedKey = UpdateHandoff.PatchFailedKey;
    private readonly UpdateFeedClient? client;
    private readonly WindowsUpdateState? state;
    private readonly Func<DateTimeOffset> now;
    private readonly Action<Action> post;
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? autoWake;
    private WindowsUpdateChannel? channel;
    private WindowsInstallationIdentity? identity;
    private string language = "en";
    private Action? installStarted;
    private volatile bool disposed, installing;
    private bool automatic;
    private DateTimeOffset lastCheck = DateTimeOffset.MinValue, offeredAt;
    private WindowsUpdatePackage? offer;
    private bool incremental;
    internal WindowsUpdateStatus Status { get; private set; } = new(false, false, "windows.updates.unconfigured");
    /// When Pacer last asked for an update, if it ever has.
    internal DateTimeOffset? LastCheck => lastCheck == DateTimeOffset.MinValue ? null : lastCheck;
    internal event Action<WindowsUpdateStatus>? Changed;
    internal IWindowsUpdatePresenter? Presenter { get; set; }
    /// What Install would download: the patch when it applies to this
    /// installation, otherwise the full installer.
    internal WindowsUpdatePackage? CurrentOffer => offer == null ? null : incremental ? offer.AsIncremental() : offer;
    internal WindowsUpdateService(Action<Action> post, UpdateFeedClient? client = null, WindowsUpdateState? state = null, Func<DateTimeOffset>? now = null)
    {
        this.post = post; this.client = client; this.state = state; this.now = now ?? (() => DateTimeOffset.UtcNow);
    }
    private void Publish(WindowsUpdateStatus value) { if (disposed) return; Status = value; Changed?.Invoke(value); }
    internal async Task InitializeAsync(WindowsUpdateChannel channel, WindowsInstallationIdentity identity, string language, bool automatic, Action installStarted)
    {
        if (client == null || disposed) return;
        this.channel = channel; this.identity = identity; this.language = language; this.installStarted = installStarted; this.automatic = automatic;
        try
        {
            await Task.Run(() =>
            {
                if (state?.Read(LastCheckKey) is string saved && long.TryParse(saved, NumberStyles.Integer, CultureInfo.InvariantCulture, out long seconds))
                    lastCheck = DateTimeOffset.FromUnixTimeSeconds(seconds);
                state?.Write(AutomaticKey, automatic ? "1" : "0");
            }).WaitAsync(TimeSpan.FromSeconds(10));
            Publish(new(true, false, "updates.policy")); ArmAutomatic();
        }
        catch (Exception error) when (Recoverable(error)) { Publish(new(false, false, "windows.updates.failed")); }
    }
    internal async Task<string?> ReadReleaseNotesAsync()
    {
        if (disposed || installing || client == null || !Status.Available || Status.Busy) return null;
        string? notes = await client.ReadReleaseNotesAsync(lifetime.Token);
        return disposed ? null : notes;
    }
    internal Task<bool> CheckAsync() => CheckCore(manual: true);
    internal Task<bool> CheckAutomaticIfDueAsync() => automatic && now() - lastCheck >= AutomaticInterval
        ? CheckCore(manual: false) : Task.FromResult(false);
    private async Task<bool> CheckCore(bool manual)
    {
        if (client == null || disposed || installing || !Status.Available || Status.Busy || !await operations.WaitAsync(0)) return false;
        try
        {
            autoWake?.Cancel(); lastCheck = now();
            if (manual) { Publish(Status with { Busy = true, MessageKey = "updates.checking" }); Presenter?.Checking(); }
            WindowsUpdatePackage? found;
            try
            {
                found = await client.ReadOfferAsync(lifetime.Token);
                state?.Write(LastCheckKey, lastCheck.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
            }
            catch (Exception error) when (Recoverable(error))
            {
                if (disposed) return false;
                if (manual) { Publish(Status with { Busy = true, MessageKey = "windows.updates.failed" }); Presenter?.Failed(); }
                else Publish(Status with { MessageKey = "windows.updates.failed" });
                return false;
            }
            if (disposed) return false;
            // A skipped build stays quiet until a newer one appears; a manual check still offers it.
            if (found != null && !manual && state?.Read(SkipKey) == found.Build.ToString()) found = null;
            if (found == null)
            {
                if (manual) { Publish(Status with { Busy = true, MessageKey = "updates.no_update" }); Presenter?.UpToDate(); }
                else Publish(Status with { MessageKey = "updates.no_update" });
                return true;
            }
            offer = found; offeredAt = now(); incremental = await Task.Run(() => PatchApplies(found));
            Publish(new(true, true, "windows.updates.available")); Presenter?.Offer(CurrentOffer!, manual);
            return true;
        }
        finally { operations.Release(); if (!Status.Busy) ArmAutomatic(); }
    }
    /// Downloads and verifies the current offer into a new session directory.
    /// An offer older than OfferLifetime is verified again first; a different
    /// result replaces it and fails this download.
    internal async Task<VerifiedDownload> DownloadAsync(IProgress<UpdateProgress>? progress, CancellationToken cancellation)
    {
        if (client == null || identity == null || offer == null || disposed || installing) throw new InvalidOperationException("No update is offered.");
        if (now() - offeredAt > OfferLifetime)
        {
            var fresh = await client.ReadOfferAsync(cancellation);
            if (fresh == null || fresh != offer)
            {
                offer = fresh; offeredAt = now(); incremental = fresh != null && await Task.Run(() => PatchApplies(fresh));
                throw new InvalidDataException("The offered update changed.");
            }
            offeredAt = now();
        }
        var item = CurrentOffer!;
        string session = UpdateSessions.Create(identity);
        Publish(Status with { MessageKey = "windows.updates.downloading" });
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        try { return await client.DownloadAsync(item, session, progress, linked.Token); }
        catch { UpdateSessions.Clean(identity.DataRoot); throw; }
    }
    /// Hands a verified download to the helper; the app then quits.
    internal bool Install(VerifiedDownload download)
    {
        if (disposed || installing || channel == null || identity == null || offer == null || download.Package != CurrentOffer) return false;
        var prepared = UpdateHandoff.Prepare(download, channel, identity, Path.Combine(identity.Root, "Maintenance", "PacerMaintenance.exe"), language);
        UpdateHandoff.Start(prepared); installing = true;
        Publish(Status with { MessageKey = "windows.updates.installing" });
        post(() => installStarted?.Invoke()); return true;
    }
    // A patch is used only for the exact installation it was built from, and
    // not again for a build whose patch already failed to install here. The
    // installer checks every file again before it replaces anything.
    private bool PatchApplies(WindowsUpdatePackage package)
    {
        if (package.Patch is not { } patch || identity == null) return false;
        try
        {
            return state?.Read(PatchFailedKey) != package.Build.ToString() &&
                UpdateCatalog.InstalledManifest(identity.Root) == patch.BaseManifestSHA256;
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }
    /// After a patch failed to install, offers the same update again, now as
    /// the full installer, without waiting for the next daily check.
    internal Task<bool> RetryAfterFailedPatchAsync() => CheckCore(manual: false);
    /// Remembers the offered build so automatic checks stay quiet about it.
    internal void Skip()
    {
        if (offer != null) try { state?.Write(SkipKey, offer.Build.ToString()); } catch (Exception error) when (Recoverable(error)) { }
        Dismiss();
    }
    /// Closes the update window: any unfinished download is discarded.
    internal void Dismiss()
    {
        if (disposed || installing) return;
        bool offered = offer != null;
        offer = null; incremental = false;
        if (identity != null) try { UpdateSessions.Clean(identity.DataRoot); } catch (Exception error) when (Recoverable(error)) { }
        Publish(Status with { Busy = false, MessageKey = offered || Status.MessageKey is "updates.checking" or "windows.updates.downloading" ? "updates.cancelled" : Status.MessageKey });
        ArmAutomatic();
    }
    private void ArmAutomatic()
    {
        autoWake?.Cancel(); autoWake?.Dispose(); autoWake = null;
        if (disposed || !automatic || state == null || !Status.Available || Status.Busy || installing) return;
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
        if (client == null || disposed || !Status.Available || !await operations.WaitAsync(0)) return false;
        try { await Task.Run(() => state?.Write(AutomaticKey, value ? "1" : "0")).WaitAsync(TimeSpan.FromSeconds(3)); automatic = value; ArmAutomatic(); return true; }
        catch (Exception error) when (Recoverable(error)) { Publish(Status with { MessageKey = "windows.updates.failed" }); return false; }
        finally { operations.Release(); }
    }
    internal async Task<bool> ApplyAutomaticAsync(bool value, PreferencesSession preferences)
    {
        bool previous = preferences.Current.AutomaticUpdates;
        if (!await SetAutomaticAsync(value)) { _ = await SetAutomaticAsync(previous); return false; }
        if (await preferences.ChangeAsync(current => current with { AutomaticUpdates = value }) == PreferencesApplyResult.Applied) return true;
        _ = await SetAutomaticAsync(previous); return false;
    }
    internal static bool Recoverable(Exception error) => error is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException
        or ArgumentException or System.ComponentModel.Win32Exception or TimeoutException or OperationCanceledException or System.Text.Json.JsonException
        or System.Security.Cryptography.CryptographicException or System.Net.Http.HttpRequestException;
    public ValueTask DisposeAsync()
    {
        if (disposed) return ValueTask.CompletedTask;
        disposed = true; autoWake?.Cancel(); autoWake?.Dispose(); lifetime.Cancel();
        client?.Dispose();
        return ValueTask.CompletedTask;
    }
}
