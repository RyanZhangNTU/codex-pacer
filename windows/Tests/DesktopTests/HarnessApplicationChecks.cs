using CodexPacer.Windows;

internal static class HarnessApplicationChecks
{
    internal static int CheckIdentity(string engineDirectory, string? executable)
    {
        var native = new WindowsHarnessApplication(engineDirectory);
        string? candidate = executable ?? native.Locate();
        bool valid = candidate != null && native.IsApplication(candidate);
        Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { located = candidate != null, valid, launched = false }));
        return valid ? 0 : 1;
    }
    internal static void Run(string engineDirectory)
    {
        string source = Environment.GetEnvironmentVariable("PACER_HARNESS_DESKTOP_FIXTURE")
            ?? throw new InvalidOperationException("The synthetic Harness metadata fixture is required.");
        string root = Path.Combine(Path.GetTempPath(), "pacer-harness-中文 " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            foreach (string path in Directory.EnumerateFiles(Path.GetDirectoryName(source)!, "DeepSeek Harness.*"))
                File.Copy(path, Path.Combine(root, Path.GetFileName(path)));
            string executable = Path.Combine(root, "DeepSeek Harness.exe");
            var native = new WindowsHarnessApplication(engineDirectory);
            Check(native.IsApplication(executable), "The managed host must use the engine's PE metadata validator, including Unicode paths");
            Check(!native.IsApplication(@"\\untrusted.invalid\share\DeepSeek Harness.exe")
                && !native.IsApplication("DeepSeek Harness.exe") && !native.IsApplication(executable + "\0"),
                "Network, relative and embedded-control paths cannot become desktop launch targets");
            var opened = new List<string>(); int scans = 0;
            var apps = new WindowsDesktopApplications(_ => false, _ => throw new Exception("Unexpected MSIX activation"),
                () => { scans++; return executable; }, native.IsApplication, path => { opened.Add(path); return true; });
            Check(apps.CanOpenHarness && apps.Available() is [{ Provider: "deepseek", Executable: var locatedExecutable }] && locatedExecutable == executable && scans == 1,
                "Toolbar and notification availability must share the same bounded metadata scan");
            Check(apps.Open("deepseek") && scans == 2 && opened.SequenceEqual([executable]),
                "Opening must revalidate and pass the exact executable path without shell arguments");
            File.Delete(executable);
            Check(!apps.Open("deepseek") && !apps.CanOpenHarness && apps.Available().Count == 0 && opened.Count == 1,
                "Uninstalling after a cached scan must fail safely and remove the cached action");
            File.Copy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"), executable);
            Check(!native.IsApplication(executable) && !apps.Open("deepseek") && opened.Count == 1,
                "Replacing a candidate with a renamed system executable cannot activate it");
            File.Delete(executable); File.Copy(source, executable);
            var rejected = new WindowsDesktopApplications(_ => false, _ => false, () => executable, native.IsApplication, _ => false);
            Check(rejected.CanOpenHarness && !rejected.Open("deepseek") && !rejected.Open("deepseek --untrusted"),
                "A failed activation and unknown provider must remain failures");
            Check(!File.Exists(Path.Combine(root, "fixture-was-launched")), "Discovery and injected activation must never execute the fixture");
        }
        finally { Directory.Delete(root, recursive: true); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
