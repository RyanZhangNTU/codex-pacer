using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using CodexPacer.Windows;

/// <summary>The host's part of an engine crash report, alone and with the real engine.</summary>
internal static class EngineCrashLogChecks
{
    internal const string TruncatedFixture = "truncated";
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }

    internal static async Task Run(string executable)
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-crash-log-中文-" + Guid.NewGuid().ToString("N"));
        try
        {
            SwiftStops();
            Retention(Path.Combine(root, "retention"));
            HostOnlyReport(Path.Combine(root, "host"));
            await EngineReport(executable, Path.Combine(root, "engine"));
            await StoppedEngine(executable, Path.Combine(root, "stopped"));
            await TruncatedFrame(Path.Combine(root, "truncated"));
        }
        finally { try { Directory.Delete(root, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }
    }

    /// <summary>Of the engine's error text only the source line of a Swift stop is taken, in a fixed form.</summary>
    private static void SwiftStops()
    {
        Check(EngineCrashLog.SwiftStop("PacerEngineSupport/File.swift:3: Fatal error: could not read C:\\Users\\Synthetic User\\.codex\\x and D:\\work\\private project\\y")
            == "Fatal error at PacerEngineSupport File.swift:3", "The message after the location can quote a path and is dropped");
        Check(EngineCrashLog.SwiftStop("Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range\r") == "Fatal error at Swift ContiguousArrayBuffer.swift:600"
            && EngineCrashLog.SwiftStop("Array+Slices.swift:12: Precondition failed") == "Precondition failed at Array+Slices.swift:12"
            && EngineCrashLog.SwiftStop("Core/Plan.swift:7: Assertion failed: unexpected") == "Assertion failed at Core Plan.swift:7", "Each kind of stop, with or without a module or a message");
        foreach (string other in new[]
        {
            "C:\\Users\\Synthetic User\\project\\File.swift:3: Fatal error: stopped", "D:/work/private project/File.swift:3: Fatal error",
            "read D:\\work\\private project\\notes.txt", "note Module/File.swift:3: Fatal error: later in a line", "Module/File.swift:3: error: something else",
            "Module/File.swift:3: Fatal errors", "private project/File.swift:3: Fatal error", "*** Program crashed: Illegal instruction at 0x00007ff81e27bede ***", "0    0x00007ff81e20cea9", ""
        })
            Check(EngineCrashLog.SwiftStop(other) == null, "Nothing else is taken: " + other);
    }

    private static void Retention(string directory)
    {
        Directory.CreateDirectory(directory);
        for (int index = 0; index < 14; index++)
            File.WriteAllText(Path.Combine(directory, EngineCrashLog.Prefix + "202601" + (10 + index) + "-000000-0000000" + (index % 10) + ".txt"), "report " + index);
        File.WriteAllText(Path.Combine(directory, EngineCrashLog.Prefix + "20260131-000000-00000999.txt"), "");
        File.WriteAllText(Path.Combine(directory, "unrelated.txt"), "kept");
        Check(EngineCrashLog.Prepare(directory, "1.2.3.4") != null, "An existing folder is prepared");
        string[] names = Directory.GetFiles(directory).Select(Path.GetFileName).OrderBy(name => name, StringComparer.Ordinal).ToArray()!;
        Check(names.Length == EngineCrashLog.Kept + 1 && names.Contains("unrelated.txt"), "Only the newest reports are kept and other files are left alone");
        Check(!names.Any(name => name.Contains("-00000999.")) && names[0].Contains("20260114") && names[^2].Contains("20260123"), "Empty leftovers and the oldest reports go first");
        Check(EngineCrashLog.Prepare(Path.Combine(directory, "unrelated.txt", "below"), "1.2.3.4") == null, "A folder that cannot exist disables reports without failing the start");
    }

    private static void HostOnlyReport(string directory)
    {
        var log = new EngineCrashLog(directory, "1.2.3.4");
        var now = new DateTimeOffset(2026, 11, 10, 2, 3, 4, TimeSpan.Zero);
        string identifier = EngineCrashLog.NewIdentifier(now), other = EngineCrashLog.NewIdentifier(now);
        Check(Regex.IsMatch(identifier, "^20261110-020304-[0-9a-f]{8}$") && identifier != other, "Each start has an identifier of its own, even within one second");
        Check(log.Complete(identifier, 4242, 0, TimeSpan.FromSeconds(9), null, now) == null && !Directory.Exists(directory), "An engine that ends without an error leaves no report");
        string report = log.Complete(identifier, 4242, unchecked((int)0xC0000409), TimeSpan.FromSeconds(75.9), null, now) ?? throw new InvalidOperationException("A failed engine has a report");
        Check(report == log.ReportPath(identifier) && Path.GetFileName(report) == "engine-crash-" + identifier + ".txt", "The name carries the start's identifier");
        string[] lines = File.ReadAllLines(report);
        Check(lines[0] == EngineCrashLog.Title && lines.Contains("time: 2026-11-10T02:03:04Z") && lines.Contains("app: 1.2.3.4") && lines.Contains("process: 4242"), "The host writes the heading the engine could not");
        Check(lines.Any(line => Regex.IsMatch(line, @"^windows: 10\.0\.[0-9]{5}\.[0-9]+$")), "The update revision selects the system binaries");
        Check(lines.Contains("reason: the engine stopped without writing a report") && lines.Contains("host:") && lines.Contains("  exit: 0xC0000409") && lines.Contains("  running: 75 s"),
            "The exit code is the only trace of a fail-fast");
        Check(!lines.Any(line => line.StartsWith("  swift:", StringComparison.Ordinal)), "No Swift stop, no line for it");

        // Windows hands the same process number to a later engine. Its exit goes to its own report, not to the older one.
        string earlier = File.ReadAllText(report);
        string later = log.Complete(other, 4242, 1, TimeSpan.FromSeconds(2), "Fatal error at Core Plan.swift:7", now.AddMinutes(5)) ?? throw new InvalidOperationException("The later engine has a report");
        Check(later != report && File.ReadAllText(report) == earlier, "An earlier report with the same process number is left as it was");
        Check(File.ReadAllText(later).EndsWith("host:\n  exit: 0x00000001\n  running: 2 s\n  swift: Fatal error at Core Plan.swift:7\n", StringComparison.Ordinal), "The later engine's exit and Swift stop are in its own report");
        Check(log.Complete(EngineCrashLog.NewIdentifier(now), 4242, 0, TimeSpan.Zero, null, now) == null && Directory.GetFiles(directory).Length == 2, "A later engine that ends without an error adds nothing");
    }

    private static async Task<(int Id, int ExitCode, string Errors)> Stop(string executable, string directory, string identifier, string kind)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (string argument in new[] { "--crash-log-directory", directory, "--crash-log-id", identifier, "--app-version", "9.8.7.6", "--diagnose-crash", kind }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("The engine did not start.");
        Task<string> errors = process.StandardError.ReadToEndAsync(), output = process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        await output;
        return (process.Id, process.ExitCode, await errors);
    }

    /// <summary>The engine writes its report on a Swift fatal error; the host adds the exit code and the source line.</summary>
    private static async Task EngineReport(string executable, string directory)
    {
        Directory.CreateDirectory(directory);
        var log = EngineCrashLog.Prepare(directory, "9.8.7.6") ?? throw new InvalidOperationException("The folder is prepared");
        string identifier = EngineCrashLog.NewIdentifier(DateTimeOffset.UtcNow);
        var stopped = await Stop(executable, directory, identifier, "fatal-error");
        Check(unchecked((uint)stopped.ExitCode) == 0xC000001D, "A Swift fatal error ends the engine with an illegal instruction");
        Check(Directory.GetFiles(directory).Single() == log.ReportPath(identifier), "The engine names its report by the host's identifier");
        string engineOnly = File.ReadAllText(log.ReportPath(identifier));
        Check(engineOnly.StartsWith(EngineCrashLog.Title + "\n", StringComparison.Ordinal) && engineOnly.Contains("\nexception: 0xC000001D") && !engineOnly.Contains("host:"), "The engine wrote its part first");
        string? stop = stopped.Errors.Split('\n').Select(EngineCrashLog.SwiftStop).LastOrDefault(found => found != null);
        Check(stop != null && Regex.IsMatch(stop, @"^Fatal error at PacerEngineSupport WindowsCrashReport\.swift:[0-9]+$"), "The Swift runtime names the source line in the form the host reads");
        string report = log.Complete(identifier, stopped.Id, stopped.ExitCode, TimeSpan.FromSeconds(3), stop, DateTimeOffset.UtcNow) ?? throw new InvalidOperationException("The report is completed");
        string text = File.ReadAllText(report);
        Check(Directory.GetFiles(directory).Length == 1 && text.StartsWith(engineOnly, StringComparison.Ordinal), "The host adds to the engine's report instead of writing a second one");
        Check(text.EndsWith("\nhost:\n  exit: 0xC000001D\n  running: 3 s\n  swift: " + stop + "\n", StringComparison.Ordinal), "The source line a stack cannot show is in the report");
        Check(Regex.IsMatch(text, @"(?m)^  [0-9]+ PacerEngine\.exe\+0x[0-9A-F]+$") && text.Contains("\nmodules:\n"), "The engine's stack and modules are listed");
        Check(!text.Contains('\\') && !text.Contains('/') && !text.Contains("中文") && !text.Contains("Synthetic engine failure"), "No path and none of the engine's own text is in the report");
        Check(text.All(character => character == '\n' || (character >= ' ' && character < 127)), "A report is plain text");
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
        string open = Directory.GetFiles(directory).Single();
        Check(Regex.IsMatch(Path.GetFileName(open), "^engine-crash-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}[.]txt$"), "A running engine holds the report the host named open");
        using (var process = Process.GetProcessById(id)) process.Kill();
        string report = await stopped.Task.WaitAsync(TimeSpan.FromSeconds(20)) ?? throw new InvalidOperationException("The report exists when the stopped status arrives");
        string text = File.ReadAllText(report);
        Check(report == open && text.Contains("reason: the engine stopped without writing a report") && text.Contains("process: " + id + "\n")
            && text.Contains("  exit: 0xFFFFFFFF"), "The host reports an engine that could not, under the same name");
        Check(Directory.GetFiles(directory).Length == 1, "The engine's unwritten file went away with it");
    }

    /// <summary>
    /// Through the real client: an engine that stops in the middle of a frame is a protocol failure,
    /// and its exit is recorded all the same. The fixture is this program; see <c>Program.Fixture</c>.
    /// </summary>
    private static async Task TruncatedFrame(string directory)
    {
        var log = EngineCrashLog.Prepare(directory, "9.8.7.6") ?? throw new InvalidOperationException("The folder is prepared");
        var failed = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var engine = new EngineClient();
        engine.Status += status =>
        {
            if (status == "engineProtocolFailed") failed.TrySetResult(Directory.GetFiles(directory).SingleOrDefault());
            else if (status == "engineStopped") failed.TrySetException(new InvalidOperationException("Half a frame is not a clean end"));
        };
        await engine.StartAsync(Environment.ProcessPath!, true, TruncatedFixture, crashLog: log);
        string report = await failed.Task.WaitAsync(TimeSpan.FromSeconds(20)) ?? throw new InvalidOperationException("The report exists when the protocol failure arrives");
        string text = File.ReadAllText(report);
        Check(text.Contains("reason: the engine stopped without writing a report") && text.Contains("  exit: 0x00000007\n"), "The exit is recorded whatever the last frame looked like");
        Check(text.EndsWith("  swift: Fatal error at Fixture Engine.swift:7\n", StringComparison.Ordinal), "The client reads the source line from the engine's error text");
        Check(!text.Contains("private") && !text.Contains('\\') && !text.Contains("earlier line"), "No other error text reaches the report");
    }
}
