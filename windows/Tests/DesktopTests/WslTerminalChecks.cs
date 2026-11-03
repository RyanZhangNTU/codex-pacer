using System.Diagnostics;
using CodexPacer.Windows;

internal static class WslTerminalChecks
{
    internal static void Run()
    {
        var plan = new EngineNavigationPlan(Guid.NewGuid().ToString("D"), "codex", "wslTerminal", null, null, null, null, "e30=");
        var calls = new List<ProcessStartInfo>();
        bool Start(ProcessStartInfo info) { calls.Add(info); return true; }
        Check(WindowsWslTerminal.Launch(plan, @"C:\Synthetic App", @"C:\Terminal\wt.exe", Start), "A verified source can open its dedicated WSL console");
        Check(calls.Single().ArgumentList.SequenceEqual(new[] { "-w", "0", "new-tab", "--", @"C:\Synthetic App\Engine\PacerEngine.exe", "--wsl-terminal", "e30=" }),
            "WT receives a fixed console mode and base64 token, never a shell command or Linux path");
        calls.Clear();
        Check(WindowsWslTerminal.Launch(plan, @"C:\Synthetic;App", @"C:\Terminal\wt.exe", Start) && calls.Single().ArgumentList.First() == "--wsl-terminal",
            "A semicolon path bypasses WT's command parser while preserving the same console");
        calls.Clear();
        foreach (var invalid in new[] { plan with { Terminal = "x;prompt" }, plan with { Url = "codex://threads/private" }, plan with { Pid = 1 },
            plan with { Provider = "deepseek" }, plan with { Kind = "application" }, plan with { Context = "bad" }, plan with { Terminal = new string('a', 16001) } })
            Check(!WindowsWslTerminal.Launch(invalid, @"C:\Synthetic App", null, Start), "Unsafe WSL plans cannot reach process launch");
        Check(calls.Count == 0, "Rejected plans must have no OS side effects");
        Check(!WindowsWslTerminal.Launch(plan, @"C:\Synthetic App", null, _ => false), "A failed console launch must preserve unread state");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
