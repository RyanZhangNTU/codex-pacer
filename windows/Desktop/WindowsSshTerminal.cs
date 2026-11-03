using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal static class WindowsSshTerminal
{
    internal static Task<bool> OpenAsync(EngineNavigationPlan plan) => Task.Run(() =>
        Launch(plan, AppContext.BaseDirectory, FindTerminal(), info => { using var child = Process.Start(info); return child != null; }));

    internal static bool Launch(EngineNavigationPlan plan, string appDirectory, string? terminal, Func<ProcessStartInfo, bool> start)
    {
        if (!Guid.TryParse(plan.Context, out _) || plan.Provider is not ("claude" or "codex") || plan.Kind != "terminal" || plan.Url != null || plan.WebUrl != null || plan.Pid != null || plan.Started != null ||
            plan.Terminal is not { Length: > 0 and <= 16000 } token || token.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('+' or '/' or '='))) return false;
        string engine = Path.Combine(appDirectory, "Engine", "PacerEngine.exe");
        ProcessStartInfo Info(string executable, params string[] arguments)
        {
            var value = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = appDirectory };
            foreach (string argument in arguments) value.ArgumentList.Add(argument);
            return value;
        }
        // WT parses semicolons itself. Only the fixed switch and a base64 token
        // cross that parser; Core revalidates the route in the console process.
        if (terminal != null && !engine.Contains(';') && !terminal.Contains(';'))
        {
            try { if (start(Info(terminal, "-w", "0", "new-tab", "--", engine, "--ssh-terminal", token))) return true; }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { }
        }
        try { return start(Info(engine, "--ssh-terminal", token)); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { return false; }
    }
    private static string? FindTerminal()
    {
        foreach (string entry in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            string directory = entry.Trim('"');
            if (!Path.IsPathFullyQualified(directory)) continue;
            string path = Path.Combine(directory, "wt.exe");
            if (File.Exists(path)) return path;
        }
        return null;
    }
}
