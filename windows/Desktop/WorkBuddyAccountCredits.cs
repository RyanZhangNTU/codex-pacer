using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

internal sealed record HarnessAccountReading(double Remaining, double Total, double Reserved, string? Plan,
    HarnessPlanCycle? Cycle, HarnessExpiringCredits? Expiration)
{
    internal double? Fraction => Total > 0 ? Math.Min(1, Remaining / Total) : null;
}
internal sealed record HarnessPlanCycle(double Total, double Remaining, double? Used, DateTimeOffset? ResetsAt);
internal sealed record HarnessExpiringCredits(double Credits, DateTimeOffset At);

internal sealed record HarnessAccountReply(string State, HarnessAccountReading? Reading = null)
{
    internal static HarnessAccountReply FromPage(JsonElement json)
    {
        if (json.ValueKind != JsonValueKind.Object || Text(json, "state") is not string state) return new("unavailable");
        if (state == "signIn") return new(state);
        if (state != "ready" || Number(json, "remaining") is not double remaining || Number(json, "total") is not double total ||
            Number(json, "reserved") is not double reserved) return new("unavailable");
        HarnessPlanCycle? cycle = null;
        if (Object(json, "cycle") is { } value && Number(value, "total") is double planTotal && Number(value, "remaining") is double planRemaining)
            cycle = new(planTotal, planRemaining, Number(value, "used"), FutureDate(value, "reset"));
        HarnessExpiringCredits? expiration = null;
        if (Object(json, "expiration") is { } expiry && FutureDate(expiry, "at") is DateTimeOffset at &&
            Number(expiry, "credits") is double credits && credits > 0 && credits <= remaining + 0.000001)
            expiration = new(credits, at);
        string? plan = Text(json, "plan") is { Length: > 0 and <= 80 } name ? name : null;
        return new("ready", new(remaining, total, reserved, plan, cycle, expiration));
    }

    private static DateTimeOffset? FutureDate(JsonElement json, string field) =>
        Number(json, field) is double epoch && epoch > DateTimeOffset.UtcNow.ToUnixTimeSeconds() && epoch < 4_102_444_800
            ? DateTimeOffset.FromUnixTimeSeconds((long)epoch) : null;
    private static JsonElement? Object(JsonElement json, string field) =>
        json.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.Object ? value : null;
    private static double? Number(JsonElement json, string field) => json.TryGetProperty(field, out var value) &&
        value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out double number) && number is >= 0 and <= 128e12 ? number : null;
    private static string? Text(JsonElement json, string field) => json.TryGetProperty(field, out var value) &&
        value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

internal interface IHarnessAccountSession : IAsyncDisposable
{
    bool Available { get; }
    bool IsConnected { get; }
    Task<HarnessAccountReply> ReadCreditsAsync(CancellationToken cancellation);
    Task<bool> SignInAsync(CancellationToken cancellation);
    Task ClearAsync(CancellationToken cancellation);
}

internal sealed class WorkBuddyAccountSession : ProviderWebSession, IHarnessAccountSession
{
    private static readonly Lazy<string> Script = new(() =>
    {
        using var stream = typeof(WorkBuddyAccountSession).Assembly.GetManifestResourceStream("CodexPacer.Windows.Assets.Web.workbuddy-scripts.json")
            ?? throw new InvalidDataException("Missing WorkBuddy credits script.");
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("summaryScript").GetString() ?? throw new InvalidDataException();
    });
    private readonly ProviderWebDefinition definition;
    private readonly string connectionReceipt;

    internal WorkBuddyAccountSession(UiText ui, bool china, string? profile = null, Action<CoreWebView2>? fixture = null, bool? dark = null)
        : this(ui, ProviderWebDefinition.WorkBuddy(china), profile ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "Web", china ? "WorkBuddyCN" : "WorkBuddyAI"),
            fixture, dark) { }

    private WorkBuddyAccountSession(UiText ui, ProviderWebDefinition definition, string profile, Action<CoreWebView2>? fixture, bool? dark)
        : base(ui, definition, profile, fixture, dark)
    {
        this.definition = definition;
        connectionReceipt = Path.Combine(Path.GetFullPath(profile), "pacer-account-connected");
    }

    public bool IsConnected => File.Exists(connectionReceipt);

    private void RemoveConnectionReceipt()
    {
        if (Directory.Exists(Path.GetDirectoryName(connectionReceipt))) File.Delete(connectionReceipt);
    }

    async Task<bool> IHarnessAccountSession.SignInAsync(CancellationToken cancellation)
    {
        RemoveConnectionReceipt();
        if (!await SignInAsync(cancellation)) return false;
        cancellation.ThrowIfCancellationRequested();
        File.WriteAllText(connectionReceipt, "1");
        return true;
    }

    async Task IHarnessAccountSession.ClearAsync(CancellationToken cancellation)
    {
        RemoveConnectionReceipt();
        await ClearAsync(cancellation);
    }

    protected override ProviderLoginWindow CreateLogin(Task<CoreWebView2Environment> environment, CancellationToken lifetime)
        => new(ui, environment, fixture, darkOverride, lifetime, definition);

    protected override async Task<string?> ReadFingerprintAsync(CancellationToken cancellation)
    {
        var result = await ReadCreditsAsync(cancellation);
        return result.State == "ready" ? "ready" : null;
    }

    public Task<HarnessAccountReply> ReadCreditsAsync(CancellationToken cancellation) => base.ReadAsync(async (page, token) =>
    {
        await page.NavigateReader(new Uri(definition.Origin, ".codex-pacer/credits/" + Guid.NewGuid().ToString("N")), token);
        return HarnessAccountReply.FromPage(await page.Evaluate(Script.Value, token));
    }, cancellation);
}

/// A host-owned, read-only account connection. The browser and the local task source have separate lifetimes.
internal sealed class HarnessAccountConnection : IAsyncDisposable
{
    private readonly IHarnessAccountSession international, china;
    private IHarnessAccountSession session;
    private readonly DispatcherTimer timer;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? operation;
    private bool enabled, sleeping, disposed;
    internal event Action? Changed;
    internal string State { get; private set; } = "signIn";
    internal HarnessAccountReading? Reading { get; private set; }
    internal bool Busy => operation != null;
    internal bool Available => !disposed && session.Available;
    internal bool CanDisconnect => session.IsConnected;

    internal HarnessAccountConnection(IHarnessAccountSession international, IHarnessAccountSession china, bool useChina, Dispatcher dispatcher)
    {
        this.international = international; this.china = china; session = useChina ? china : international;
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMinutes(2) };
    }

    internal void SetEnabled(bool value)
    {
        if (disposed || enabled == value) return;
        enabled = value;
        if (!value)
        {
            StopTimer();
            operation?.Cancel(); operation = null;
            Reading = null; State = "signIn"; Changed?.Invoke();
        }
        else if (!sleeping && session.IsConnected) _ = RefreshAsync();
    }

    internal void SetSleeping(bool value)
    {
        if (disposed || sleeping == value) return;
        sleeping = value;
        if (value)
        {
            StopTimer();
            operation?.Cancel(); operation = null;
            Reading = null; State = "signIn"; Changed?.Invoke();
        }
        else if (enabled && session.IsConnected) _ = RefreshAsync();
    }

    internal Task RefreshAsync() => RunAsync(async token =>
    {
        var result = session.IsConnected ? await session.ReadCreditsAsync(token) : new("signIn");
        token.ThrowIfCancellationRequested();
        Apply(result);
    });

    internal Task ConnectAsync() => RunAsync(async token =>
    {
        // A cancelled switch could leave the browser on a different account.
        // Hide the old reading before the login window opens.
        Apply(new("signIn")); Changed?.Invoke();
        if (await session.SignInAsync(token))
        {
            var result = await session.ReadCreditsAsync(token);
            token.ThrowIfCancellationRequested();
            Apply(result);
        }
    });

    internal Task DisconnectAsync() => RunAsync(async token =>
    {
        Apply(new("signIn"));
        await session.ClearAsync(token);
    });

    internal void SelectSite(bool useChina)
    {
        var selected = useChina ? china : international;
        if (disposed || ReferenceEquals(session, selected)) return;
        StopTimer(); operation?.Cancel(); operation = null;
        session = selected; Reading = null; State = "signIn";
        Changed?.Invoke();
        if (enabled && !sleeping && session.IsConnected) _ = RefreshAsync();
    }

    private async Task RunAsync(Func<CancellationToken, Task> run)
    {
        if (disposed || sleeping || !enabled || Busy) return;
        if (!session.Available) { Apply(new("unavailable")); Changed?.Invoke(); return; }
        var current = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        operation = current; Changed?.Invoke();
        try { await run(current.Token); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is JsonException)
        {
            if (!current.IsCancellationRequested) Apply(new("unavailable"));
        }
        finally
        {
            if (ReferenceEquals(operation, current)) { operation = null; Changed?.Invoke(); }
            current.Dispose();
        }
    }

    private void Apply(HarnessAccountReply result)
    {
        State = result.State;
        if (result.State != "unavailable") Reading = result.Reading;
        StopTimer();
        if (State != "signIn" && enabled && !sleeping && session.IsConnected)
        {
            timer.Interval = TimeSpan.FromMinutes(State == "ready" ? 2 : 5);
            timer.Tick += OnTick; timer.Start();
        }
    }

    private void StopTimer() { timer.Stop(); timer.Tick -= OnTick; }
    private async void OnTick(object? sender, EventArgs e) => await RefreshAsync();
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true; StopTimer(); lifetime.Cancel(); operation = null;
        await international.DisposeAsync(); await china.DisposeAsync(); lifetime.Dispose();
    }
}
