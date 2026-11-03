using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal static class WindowsWslTerminal
{
    internal static Task<bool> OpenAsync(EngineNavigationPlan plan) => Task.Run(() =>
        Launch(plan, AppContext.BaseDirectory, FindTerminal(), info => { using var child = Process.Start(info); return child != null; }));
    internal static bool Launch(EngineNavigationPlan plan, string appDirectory, string? terminal, Func<ProcessStartInfo, bool> start)
    {
        if (!Guid.TryParse(plan.Context, out _) || plan.Provider is not ("claude" or "codex") || plan.Kind != "wslTerminal" ||
            plan.Url != null || plan.WebUrl != null || plan.Pid != null || plan.Started != null || plan.Terminal is not { Length: > 0 and <= 16000 } token ||
            token.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('+' or '/' or '='))) return false;
        string engine = Path.Combine(appDirectory, "Engine", "PacerEngine.exe");
        ProcessStartInfo Info(string executable, params string[] arguments)
        {
            var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = appDirectory };
            foreach (string argument in arguments) info.ArgumentList.Add(argument);
            return info;
        }
        try
        {
            if (terminal != null && !terminal.Contains(';') && !engine.Contains(';') &&
                start(Info(terminal, "-w", "0", "new-tab", "--", engine, "--wsl-terminal", token))) return true;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { }
        try { return start(Info(engine, "--wsl-terminal", token)); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { return false; }
    }
    private static string? FindTerminal() => (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';')
        .Select(entry => entry.Trim('"')).Where(Path.IsPathFullyQualified).Select(path => Path.Combine(path, "wt.exe")).FirstOrDefault(File.Exists);
}
