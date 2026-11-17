using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using CodexPacer.Windows;

/// <summary>
/// The engine's heap stays above 2 GB where Windows would put it lower; see <c>EngineLaunch</c>.
/// The fixture is the real engine with high-entropy addresses switched off in its header, which
/// is what a user's Exploit Protection setting does to every program.
/// </summary>
internal static class EngineAddressSpaceChecks
{
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }

    internal static async Task Run(string executable)
    {
        CommandLines();
        string root = Path.Combine(Path.GetTempPath(), "pacer-address-guard-" + Guid.NewGuid().ToString("N"));
        string? path = Environment.GetEnvironmentVariable("PATH");
        try
        {
            await GuardedEngine(executable, Path.Combine(root, "reports"));
            // The altered engine lives outside the build, so it can never be packaged. It finds the
            // Swift runtime beside the real engine through PATH and has its own copy of the resources.
            string folder = Path.GetDirectoryName(executable)!, fixture = Path.Combine(root, "Engine"), unrandomized = Path.Combine(fixture, "PacerEngine.exe");
            Directory.CreateDirectory(fixture);
            foreach (string bundle in Directory.GetDirectories(folder, "*.resources"))
                foreach (string file in Directory.GetFiles(bundle, "*", SearchOption.AllDirectories))
                {
                    string target = Path.Combine(fixture, Path.GetRelativePath(folder, file));
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    File.Copy(file, target);
                }
            WithoutHighEntropy(executable, unrandomized);
            Environment.SetEnvironmentVariable("PATH", folder + ";" + path);
            await Diagnosed(unrandomized);
            await DetectedEngine(executable, unrandomized);
        }
        finally
        {
            Environment.SetEnvironmentVariable("PATH", path);
            try { Directory.Delete(root, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>The guarded start builds its own command line; Windows must split it back into the same arguments.</summary>
    private static void CommandLines()
    {
        string[][] cases =
        {
            new[] { @"C:\Program Files\Codex Pacer\Engine\PacerEngine.exe", "--demo", "--language", "zh-Hans" },
            new[] { "engine.exe", "", "a b", "say \"hi\"", @"C:\folder with space\", @"trailing\\", @"quote\""", @"\\server\share\中文 路径", "tab\there", "%PATH%", "^&|<>" },
            new[] { @"C:\Users\Synthetic User\AppData\Local\Programs\Codex Pacer\Engine\PacerEngine.exe", "--crash-log-directory", @"C:\Users\Synthetic User\AppData\Local\CodexPacer\CrashLogs" }
        };
        foreach (string[] arguments in cases)
        {
            string line = EngineLaunch.CommandLine(arguments[0], arguments.Skip(1));
            Check(Split(line).SequenceEqual(arguments), "Windows splits the command line back into the same arguments: " + line);
        }
        Check(EngineLaunch.CommandLine("a.exe", new[] { "--plain", "value" }) == "a.exe --plain value", "Arguments without spaces or quotes are left as they are");
    }

    /// <summary>Through the real client: a guarded engine answers, has nothing free below 2 GB and reports its exit.</summary>
    private static async Task GuardedEngine(string executable, string directory)
    {
        Directory.CreateDirectory(directory);
        var log = EngineCrashLog.Prepare(directory, "9.8.7.6") ?? throw new InvalidOperationException("The folder is prepared");
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var engine = new EngineClient();
        engine.Status += status => { if (status == "engineStopped") stopped.TrySetResult(); };
        await engine.StartAsync(executable, true, "en", crashLog: log, addressGuard: true);
        Check(engine.IsAddressGuarded && engine.IsInitialized, "The guarded engine completed the handshake over its pipes");
        int id = engine.ProcessId ?? throw new InvalidOperationException("The engine is running");
        using (var process = Process.GetProcessById(id))
        {
            Check(EngineLaunch.FreeLowAddresses(process.SafeHandle) == 0, "No address below 2 GB is left for the engine's heap");
            process.Kill();
        }
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(20));
        string text = File.ReadAllText(Directory.GetFiles(directory).Single(file => new FileInfo(file).Length != 0));
        Check(text.Contains("process: " + id + "\n") && text.Contains("  exit: 0xFFFFFFFF"), "The host reads a guarded engine's exit as it does any other");
    }

    private static void WithoutHighEntropy(string source, string destination)
    {
        byte[] image = File.ReadAllBytes(source);
        int header = BitConverter.ToInt32(image, 0x3C), characteristics = header + 24 + 70;
        Check(BitConverter.ToUInt32(image, header) == 0x00004550 && BitConverter.ToUInt16(image, header + 24) == 0x20B, "The engine is a 64-bit image");
        ushort flags = BitConverter.ToUInt16(image, characteristics);
        // IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA
        Check((flags & 0x20) != 0, "The engine is linked for high-entropy addresses");
        BitConverter.GetBytes((ushort)(flags & ~0x20)).CopyTo(image, characteristics);
        File.WriteAllBytes(destination, image);
    }

    private static async Task<(int ExitCode, string[] Lines)> Diagnose(string executable, bool guard)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(executable)!
        };
        start.ArgumentList.Add("--diagnose-low-addresses");
        using var job = new OwnedJob();
        using EngineChild child = EngineLaunch.Start(start, job, guard);
        Check(child.Guarded == guard, "A forced choice is taken");
        child.CloseInput();
        using var reader = new StreamReader(child.Output, Encoding.UTF8);
        Task<string> output = reader.ReadToEndAsync();
        Task errors = child.Errors.CopyToAsync(Stream.Null);
        await child.Process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60));
        string text = await output.WaitAsync(TimeSpan.FromSeconds(20));
        await errors.WaitAsync(TimeSpan.FromSeconds(20));
        return (child.Process.ExitCode, text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    /// <summary>The same binary, with and without the reservation: only where the heap lands differs.</summary>
    private static async Task Diagnosed(string unrandomized)
    {
        var plain = await Diagnose(unrandomized, guard: false);
        // Its lengths are wrong too while the pinned Swift has swiftlang/swift#92199; that part is the toolchain's to fix.
        Check(plain.Lines.FirstOrDefault() == "heap low", "Without high-entropy addresses Windows puts the engine's heap below 2 GB");
        var guarded = await Diagnose(unrandomized, guard: true);
        Check(guarded.ExitCode == 0 && guarded.Lines.SequenceEqual(new[] { "heap high", "utf16 128 128", "foundation ok" }),
            "With its low addresses reserved the same engine has its heap above 2 GB and its string lengths right: " + string.Join(" | ", guarded.Lines));
    }

    /// <summary>Through the real client: nobody asks for the guard; the address randomization in effect decides.</summary>
    private static async Task DetectedEngine(string executable, string unrandomized)
    {
        using var self = Process.GetCurrentProcess();
        bool randomized = EngineLaunch.Randomized(self.SafeHandle);
        await using (var usual = new EngineClient())
        {
            await usual.StartAsync(executable, true, "en", referenceFixture: true);
            Check(usual.IsAddressGuarded == !randomized, "Where Windows randomizes addresses the engine starts as it always did");
        }
        await using var engine = new EngineClient();
        await engine.StartAsync(unrandomized, true, "en", referenceFixture: true);
        Check(engine.IsAddressGuarded && engine.IsInitialized, "An engine without randomized addresses is started guarded");
        using var process = Process.GetProcessById(engine.ProcessId ?? throw new InvalidOperationException("The engine is running"));
        Check(!EngineLaunch.Randomized(process.SafeHandle), "Windows reports that this engine's addresses are not randomized");
        Check(EngineLaunch.FreeLowAddresses(process.SafeHandle) == 0, "No address below 2 GB is left for its heap");
    }

    private static string[] Split(string line)
    {
        IntPtr values = CommandLineToArgvW(line, out int count);
        if (values == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Enumerable.Range(0, count).Select(index => Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, index * IntPtr.Size))!).ToArray(); }
        finally { LocalFree(values); }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string line, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
