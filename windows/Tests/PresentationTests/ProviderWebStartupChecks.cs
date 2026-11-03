using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using CodexPacer.Windows;

internal static class ProviderWebStartupChecks
{
    internal static async Task Run()
    {
        await ReadyBeforeAnnouncing();
        await FailedStartupCanRetry();
        await QuitDuringStartup();
        Console.WriteLine("PASS browser startup: coalesced private-profile prewarm, no read before readiness, failed-start recovery and cancellation on quit");
    }
    private static async Task FailedStartupCanRetry()
    {
        await using var engine = new EngineClient();
        var session = new PendingSession { FailStartup = true };
        await using var coordinator = new ClaudeConnectionCoordinator(engine, session, Application.Current.Dispatcher);
        await Start(engine);
        await coordinator.StartAsync();
        Check(!coordinator.Available && engine.LatestSnapshot?.ClaudeConnection?.WebAvailable != true &&
            coordinator.LastFailure != null && session.Reads == 0,
            "Failed startup must leave the bridge unavailable without reading cookies");
        session.FailStartup = false; session.Ready.TrySetResult();
        await coordinator.StartAsync();
        await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.ClaudeConnection?.WebAvailable == true,
            "The prepared browser must publish its availability");
        Check(session.Starts == 2 && coordinator.Available && engine.LatestSnapshot?.ClaudeConnection?.WebAvailable == true,
            "A later start must retry preparation and enable only the prepared browser");
    }
    private static async Task ReadyBeforeAnnouncing()
    {
        await using var engine = new EngineClient();
        var session = new PendingSession();
        await using var coordinator = new ClaudeConnectionCoordinator(engine, session, Application.Current.Dispatcher);
        await Start(engine);
        var first = coordinator.StartAsync();
        var second = coordinator.StartAsync();
        await session.Entered.Task.WaitAsync(TimeSpan.FromSeconds(8));
        Check(session.Starts == 1 && session.Reads == 0, "Concurrent starts must share one prewarm without reading a not-ready browser");
        Check(!coordinator.Available && engine.LatestSnapshot?.ClaudeConnection?.WebAvailable != true,
            "The engine cannot request cookies before private-profile startup completes");
        session.Ready.TrySetResult();
        await Task.WhenAll(first, second);
        await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.ClaudeConnection?.WebAvailable == true,
            "The coalesced startup must publish the prepared browser");
        Check(coordinator.Available && engine.LatestSnapshot?.ClaudeConnection?.WebAvailable == true,
            "A prepared browser must enable the original bridge");
    }
    private static async Task QuitDuringStartup()
    {
        await using var engine = new EngineClient();
        var session = new PendingSession();
        var coordinator = new ClaudeConnectionCoordinator(engine, session, Application.Current.Dispatcher);
        await Start(engine);
        var starting = coordinator.StartAsync();
        await session.Entered.Task.WaitAsync(TimeSpan.FromSeconds(8));
        await coordinator.DisposeAsync();
        await starting;
        Check(session.Cancelled && session.Disposed && session.Reads == 0 && !coordinator.Available,
            "Quit must release startup without publishing availability or reading cookies");
    }
    private static Task Start(EngineClient engine) => engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"),
        true, "en", configuration: new { enabledProviders = new[] { "claude" } }, referenceFixture: true, claudeWebFixture: true);
    private sealed class PendingSession : IClaudeWebSession
    {
        internal readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Starts, Reads;
        internal bool Cancelled, Disposed, FailStartup;
        public bool Available => true;
        public async Task PrepareAsync(CancellationToken cancellation)
        {
            Starts++; Entered.TrySetResult();
            if (FailStartup) throw new IOException("Synthetic startup failure");
            try { await Ready.Task.WaitAsync(cancellation); }
            catch (OperationCanceledException) { Cancelled = true; throw; }
        }
        public Task<ClaudeWebSessionValue?> ReadAsync(CancellationToken cancellation) { Reads++; return Task.FromResult<ClaudeWebSessionValue?>(null); }
        public Task<bool> SignInAsync() => Task.FromResult(false);
        public Task ClearAsync(CancellationToken cancellation) => Task.CompletedTask;
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
