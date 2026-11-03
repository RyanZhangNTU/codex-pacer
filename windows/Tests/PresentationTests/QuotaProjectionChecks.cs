using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexPacer.Windows;

internal static class QuotaProjectionChecks
{
    internal static async Task Run()
    {
        await using var engine = new EngineClient(); EngineSnapshot? latest = null;
        engine.Snapshot += value => latest = value;
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
        await PresentationWait.UntilAsync(() => latest?.QuotaDashboard?.Providers.Any(value => value.Provider == "codex") == true
            && latest.QuotaDashboard.Providers.Any(value => value.Provider == "claude"),
            "The quota drawing fixture must receive all reference providers");
        var dashboard = latest!.QuotaDashboard ?? throw new InvalidOperationException("The real engine must project dashboard readings.");
        var codex = dashboard.Providers.Single(value => value.Provider == "codex");
        var foreign = new EngineQuota("codex", latest.CapturedAt, false,
            [new("foreign/five", "foreign", 99, 70, null, 300, latest.CapturedAt + 3600, ValueText: "99"),
             new("foreign/week", "foreign", 98, 70, null, 10080, latest.CapturedAt + 3600, ValueText: "98")]);
        var dial = new QuotaDial("codex", foreign, null, dashboard: codex);
        Check(!dial.Split && dial.Weekly?.RemainingPercent == codex.Weekly.RemainingPercent,
            "A renderer cannot borrow a model-scoped 5h window or value over the common provider reading");
        string name = UIElementAutomationPeer.CreatePeerForElement(dial).GetName();
        Check(name.Contains("43%") && !name.Contains("99%") && !name.Contains("98%"),
            "Accessibility must use the same isolated provider reading as the visible ring");

        var claude = dashboard.Providers.Single(value => value.Provider == "claude");
        var raw = latest.Quota.Single(value => value.Provider == "claude");
        var expiredWeek = claude with { Weekly = claude.Weekly with { Availability = "stale", Pressing = false, Verdict = null, VerdictText = null, PacePercent = null } };
        var fresh = Render(new QuotaDial("claude", raw, null, dashboard: claude));
        var stale = Render(new QuotaDial("claude", raw with { Stale = true }, null, dashboard: expiredWeek));
        var freshArcs = fresh.Where(value => value.Arc).ToArray();
        var staleArcs = stale.Where(value => value.Arc).ToArray();
        double shortFresh = freshArcs[0].Intensity, shortStale = staleArcs[0].Intensity;
        double weekFresh = freshArcs[1].Intensity, weekStale = staleArcs[1].Intensity;
        Check(shortFresh > 100 && Math.Abs(shortFresh - shortStale) <= 2,
            "An expired weekly window must not dim its still-fresh five-hour arc");
        Check(weekFresh > 100 && weekStale / weekFresh is > 0.48 and < 0.62,
            "Only the stale period must use the native 0.55 ring opacity");
        Console.WriteLine("PASS quota projection: real-engine provider isolation, accessibility and independent stale-period vector opacity");
    }
    private static System.Collections.Generic.IReadOnlyList<DrawingInspection.Paint> Render(QuotaDial dial)
        => DrawingInspection.Render(dial, 104, 104);
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
