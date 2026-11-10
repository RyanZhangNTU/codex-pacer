using System.Diagnostics;
using System.Text;
using CodexPacer.Windows;

/// <summary>The host's part of an engine crash report, alone and with the real engine.</summary>
internal static class EngineCrashLogChecks
{
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }

    internal static async Task Run(string executable)
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-crash-log-中文-" + Guid.NewGuid().ToString("N"));
        try
        {
            Redaction(root);
            Retention(Path.Combine(root, "retention"));
            HostOnlyReport(Path.Combine(root, "host"));
            await EngineReport(executable, Path.Combine(root, "engine"));
            await StoppedEngine(executable, Path.Combine(root, "stopped"));
        }
        finally { try { Directory.Delete(root, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }
    }

    private static void Redaction(string root)
    {
        var log = new EngineCrashLog(root, "1.2.3.4", @"C:\Users\Synthetic User");
        string text = log.Redact("first\r\nPacerEngineSupport/File.swift:3: Fatal error: could not read C:\\Users\\Synthetic User\\.codex\\x and c:/users/synthetic user/y\n"
            + "json \\\\Users\\\\other\\\\z and /c/Users/third/w\u0001\n");
        Check(!text.Contains("Synthetic", StringComparison.OrdinalIgnoreCase) && !text.Contains("other") && !text.Contains("third"), "A user's folder never reaches the report");
        Check(text.Contains(@"%USERPROFILE%\.codex\x") && text.Contains("%USERPROFILE%/y"), "The rest of a path stays readable");
        Check(text.Contains("Fatal error: could not read") && !text.Contains('\r') && !text.Contains('\u0001'), "The message is kept as printable lines");
        string dumped = log.Redact("File.swift:3: Fatal error: stopped\n\n*** Exception c000001d: Backtracing from 0x7ff81e27bede... done ***\nRegisters:\nrsp 0x1 66 61 74 61  fata\n");
        Check(dumped == "File.swift:3: Fatal error: stopped" && log.Redact("*** Program crashed ***\nRegisters:") == "", "The Swift runtime's own backtrace prints memory and is left out");
        Check(log.Redact("File.swift:3: Fatal error: stopped\nCurrent stack trace:\n0    0x00007ff81e20cea9\n") == "File.swift:3: Fatal error: stopped", "Bare addresses after the message repeat the report's stack");
        string longText = log.Redact(string.Join('\n', Enumerable.Range(0, 400).Select(index => "line " + index)));
        Check(longText.Length <= EngineCrashLog.MaximumOutput && longText.EndsWith("line 399", StringComparison.Ordinal) && longText.StartsWith("line ", StringComparison.Ordinal),
            "Only the end of long output is kept, from the start of a line");
    }

    private static void Retention(string directory)
    {
        Directory.CreateDirectory(directory);
        for (int index = 0; index < 14; index++)
            File.WriteAllText(Path.Combine(directory, EngineCrashLog.Prefix + "202601" + (10 + index) + "-000000-" + (100 + index) + ".txt"), "report " + index);
        File.WriteAllText(Path.Combine(directory, EngineCrashLog.Prefix + "20260131-000000-999.txt"), "");
        File.WriteAllText(Path.Combine(directory, "unrelated.txt"), "kept");
        Check(EngineCrashLog.Prepare(directory, "1.2.3.4") != null, "An existing folder is prepared");
        string[] names = Directory.GetFiles(directory).Select(Path.GetFileName).OrderBy(name => name, StringComparer.Ordinal).ToArray()!;
        Check(names.Length == EngineCrashLog.Kept + 1 && names.Contains("unrelated.txt"), "Only the newest reports are kept and other files are left alone");
        Check(!names.Any(name => name.Contains("-999.")) && names[0].Contains("20260114") && names[^2].Contains("20260123"), "Empty leftovers and the oldest reports go first");
        Check(EngineCrashLog.Prepare(Path.Combine(directory, "unrelated.txt", "below"), "1.2.3.4") == null, "A folder that cannot exist disables reports without failing the start");
    }

    private static void HostOnlyReport(string directory)
    {
        var log = new EngineCrashLog(directory, "1.2.3.4", @"C:\Users\Synthetic User");
        var now = new DateTimeOffset(2026, 11, 10, 2, 3, 4, TimeSpan.Zero);
        Check(log.Complete(4242, 0, TimeSpan.FromSeconds(9), "", now) == null && !Directory.Exists(directory), "An engine that ends without an error leaves no report");
        string report = log.Complete(4242, unchecked((int)0xC0000409), TimeSpan.FromSeconds(75.9), "", now) ?? throw new InvalidOperationException("A failed engine has a report");
        Check(Path.GetFileName(report) == "engine-crash-20261110-020304-4242.txt", "The name carries the time and the process");
        string[] lines = File.ReadAllLines(report);
        Check(lines[0] == EngineCrashLog.Title && lines.Contains("time: 2026-11-10T02:03:04Z") && lines.Contains("app: 1.2.3.4") && lines.Contains("process: 4242"), "The host writes the heading the engine could not");
        Check(lines.Any(line => System.Text.RegularExpressions.Regex.IsMatch(line, @"^windows: 10\.0\.[0-9]{5}\.[0-9]+$")), "The update revision selects the system binaries");
        Check(lines.Contains("reason: the engine stopped without writing a report") && lines.Contains("host:") && lines.Contains("  exit: 0xC0000409") && lines.Contains("  running: 75 s"),
            "The exit code is the only trace of a fail-fast");
        Check(!lines.Contains("  last output:"), "No output, no heading for it");
    }

    private static async Task<(int Id, int ExitCode, string Errors)> Stop(string executable, string directory, string kind)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (string argument in new[] { "--crash-log-directory", directory, "--app-version", "9.8.7.6", "--diagnose-crash", kind }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("The engine did not start.");
        Task<string> errors = process.StandardError.ReadToEndAsync(), output = process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        await output;
        return (process.Id, process.ExitCode, await errors);
    }

    /// <summary>The engine writes its report on a Swift fatal error; the host adds the exit code and the message.</summary>
    private static async Task EngineReport(string executable, string directory)
    {
        Directory.CreateDirectory(directory);
        var log = EngineCrashLog.Prepare(directory, "9.8.7.6") ?? throw new InvalidOperationException("The folder is prepared");
        var stopped = await Stop(executable, directory, "fatal-error");
        Check(unchecked((uint)stopped.ExitCode) == 0xC000001D, "A Swift fatal error ends the engine with an illegal instruction");
        string engineOnly = File.ReadAllText(Directory.GetFiles(directory).Single());
        Check(engineOnly.StartsWith(EngineCrashLog.Title + "\n", StringComparison.Ordinal) && engineOnly.Contains("\nexception: 0xC000001D") && !engineOnly.Contains("host:"), "The engine wrote its part first");
        string report = log.Complete(stopped.Id, stopped.ExitCode, TimeSpan.FromSeconds(3), stopped.Errors, DateTimeOffset.UtcNow) ?? throw new InvalidOperationException("The report is completed");
        string text = File.ReadAllText(report);
        Check(Directory.GetFiles(directory).Length == 1 && text.StartsWith(engineOnly, StringComparison.Ordinal), "The host adds to the engine's report instead of writing a second one");
        Check(text.Contains("\nhost:\n  exit: 0xC000001D\n  running: 3 s\n  last output:\n") && text.Contains("Fatal error: Synthetic engine failure"), "The message a stack cannot show is in the report");
        Check(System.Text.RegularExpressions.Regex.IsMatch(text, @"(?m)^  [0-9]+ PacerEngine\.exe\+0x[0-9A-F]+$") && text.Contains("\nmodules:\n"), "The engine's stack and modules are listed");
        Check(!text.Contains(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase) && !text.Contains("中文"), "No folder of the user is in the report");
        Check(!text.Contains("Backtracing") && !text.Contains("Registers:"), "A backtrace the Swift runtime printed after the message stays out");
    }

    /// <summary>Through the real client: an engine ended from outside leaves the host's report before the stopped status.</summary>
    private static async Task StoppedEngine(string executable, string directory)
    {
        var log = EngineCrashLog.Prepare(directory, "9.8.7.6") ?? throw new InvalidOperationException("The folder is prepared");
        var stopped = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var engine = new EngineClient();
        engine.Status += status => { if (status == "engineStopped") stopped.TrySetResult(Directory.GetFiles(directory).FirstOrDefault(file => new FileInfo(file).Length != 0)); };
        await engine.StartAsync(executable, true, "en", crashLog: log);
        int id = engine.ProcessId ?? throw new InvalidOperationException("The engine is running");
        Check(Directory.GetFiles(directory, "*-" + id + ".txt").Length == 1, "A running engine holds its report open");
        using (var process = Process.GetProcessById(id)) process.Kill();
        string report = await stopped.Task.WaitAsync(TimeSpan.FromSeconds(20)) ?? throw new InvalidOperationException("The report exists when the stopped status arrives");
        string text = File.ReadAllText(report);
        Check(Path.GetFileName(report).EndsWith("-" + id + ".txt", StringComparison.Ordinal) && text.Contains("reason: the engine stopped without writing a report")
            && text.Contains("  exit: 0xFFFFFFFF"), "The host reports an engine that could not");
        Check(Directory.GetFiles(directory).Length == 1, "The engine's unwritten file went away with it");
    }
}
