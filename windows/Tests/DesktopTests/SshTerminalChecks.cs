using System.Diagnostics;
using System.Text.Json;
using CodexPacer.Windows;

internal static class SshTerminalChecks
{
    internal static void Run()
    {
        var calls = new List<ProcessStartInfo>();
        var plan = new EngineNavigationPlan(Guid.NewGuid().ToString(), "claude", "terminal", null, null, null, null, "eyJzeW50aGV0aWMiOnRydWV9");
        bool Start(ProcessStartInfo info) { calls.Add(info); return true; }
        string app = @"C:\合成 app";
        Check(WindowsSshTerminal.Launch(plan, app, @"C:\tools\wt.exe", Start), "Windows Terminal accepts an individual argv list");
        Check(calls[0].ArgumentList.SequenceEqual(new[] { "-w", "0", "new-tab", "--", Path.Combine(app, "Engine", "PacerEngine.exe"), "--ssh-terminal", plan.Terminal! }),
            "WT only receives the fixed command and base64 plan, without shell metacharacters");
        Check(!calls[0].UseShellExecute && !calls[0].CreateNoWindow && calls[0].Arguments == "", "Terminal launch never builds a shell command string");
        calls.Clear();
        Check(WindowsSshTerminal.Launch(plan, app, null, Start) && calls[0].FileName.EndsWith("PacerEngine.exe") && calls[0].ArgumentList.Count == 2,
            "A missing WT falls back to a console with the same engine-validated plan");
        calls.Clear();
        Check(WindowsSshTerminal.Launch(plan, app + ";fixture", "wt.exe", Start) && calls.Count == 1 && calls[0].FileName.EndsWith("PacerEngine.exe"),
            "A semicolon in the application path uses the console fallback and never reaches WT's command parser");
        calls.Clear();
        Check(WindowsSshTerminal.Launch(plan, app, "wt.exe", info => { calls.Add(info); return calls.Count > 1; }) && calls.Count == 2,
            "A failed WT activation falls back once without polling");
        foreach (var invalid in new[] { plan with { Terminal = "abc;bad" }, plan with { Url = "https://example.invalid" }, plan with { Pid = 1 }, plan with { Terminal = new string('x', 16001) } })
            Check(!WindowsSshTerminal.Launch(invalid, app, null, _ => throw new InvalidOperationException()), "Malformed terminal plans cannot reach process launch");
        var defaults = PreferencesCodec.Decode("{\"schemaVersion\":2}"u8);
        Check(defaults.MonitorSSH, "An absent monitorSSH key has the Mac default true");
        byte[] bytes = PreferencesCodec.Encode(defaults with { MonitorSSH = false });
        Check(!JsonDocument.Parse(bytes).RootElement.GetProperty("monitorSSH").GetBoolean() && !PreferencesCodec.Decode(bytes).MonitorSSH,
            "The Mac preference key and disabled value survive persistence");
        Check(JsonSerializer.Serialize((defaults with { MonitorSSH = false }).EngineConfiguration()).Contains("\"monitorSSH\":false"),
            "The persisted setting reaches engine configuration");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
