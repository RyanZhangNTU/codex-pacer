using CodexPacer.Windows;

internal static class Program
{
    [STAThread]
    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length is < 3 or > 4) return 2;
            Guid? scope = args[1] == "default" ? null : Guid.ParseExact(args[1], "N");
            var identity = new WindowsInstallationIdentity(WindowsInstallationIdentity.SafeRoot(args[2]), scope);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            // Bound a stalled synchronous OS/COM call without a crash dump.
            using var watchdog = new Timer(_ => Environment.Exit(124), null, TimeSpan.FromSeconds(35), Timeout.InfiniteTimeSpan);
            var operations = new WindowsInstallationOperations(identity);
            switch (args[0])
            {
                case "prepare" when args.Length == 4: await operations.PrepareAsync(args[3], deadline.Token); break;
                case "register" when args.Length == 3: operations.Register(); break;
                case "uninstall" when args.Length == 3:
                case "uninstall-continue" when args.Length == 3:
                    var failure = await operations.UninstallAsync(deadline.Token, continueAfterFailure: args[0] == "uninstall-continue");
                    // Fixed exit codes are the installer protocol. Never forward
                    // exception text, configuration contents or provider paths.
                    if (failure.HasFlag(UninstallFailure.ClaudeConfiguration)) Console.Error.WriteLine("Pacer Claude configuration cleanup failed; settings were preserved for manual cleanup.");
                    if (failure.HasFlag(UninstallFailure.Registrations)) Console.Error.WriteLine("Pacer Windows registration cleanup failed; retained items need manual cleanup.");
                    if (failure != UninstallFailure.None) WriteCleanupLog(identity, failure);
                    return failure == UninstallFailure.None ? 0 : 20 + (int)failure;
                case "startup-enable" when args.Length == 3:
                    _ = WindowsInstallationIdentity.Load(identity.Root, scope, true);
                    if (!identity.Startup().Set(true)) return 1; break;
                case "startup-disable" when args.Length == 3:
                    _ = WindowsInstallationIdentity.Load(identity.Root, scope, true);
                    if (!identity.Startup().Set(false)) return 1; break;
                case "startup-status" when args.Length == 3:
                    _ = WindowsInstallationIdentity.Load(identity.Root, scope, true);
                    var state = identity.Startup().Read();
                    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { state.Registered, state.Available, state.Effective, BlockReason = state.BlockReason.ToString() }));
                    break;
                default: return 2;
            }
            return 0;
        }
        catch
        {
            Console.Error.WriteLine("Pacer maintenance could not finish. Close this installation and repair it before trying again.");
            return 1;
        }
    }

    private static void WriteCleanupLog(WindowsInstallationIdentity identity, UninstallFailure failure)
    {
        try
        {
            // A bounded, fixed report is also available for direct /SILENT
            // launches without Inno's /LOG option. No provider paths or data.
            string path = Path.Combine(identity.DataRoot, "uninstall-cleanup.log");
            WindowsInstallationIdentity.RequireNoReparse(path);
            Directory.CreateDirectory(identity.DataRoot);
            string temporary = Path.Combine(identity.DataRoot, ".uninstall-log-" + Guid.NewGuid().ToString("N"));
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new StreamWriter(file))
                {
                    writer.WriteLine("Pacer uninstall cleanup code " + (20 + (int)failure));
                    if (failure.HasFlag(UninstallFailure.ClaudeConfiguration)) writer.WriteLine("Claude configuration or owned runtime cleanup failed. Check settings.json and pacer/installation.json in the configured Claude homes. Remove only Pacer hook commands; restore previousStatusLine only if statusLine still uses Pacer, and remove only unchanged addedEnvironment values. Retained Pacer commands can cause Claude Code errors after application removal. Shared Python versions are under %LOCALAPPDATA%/CodexPacer/ClaudeRuntime: keep any version still referenced by a hook, and preserve unknown or modified files.");
                    if (failure.HasFlag(UninstallFailure.Registrations)) writer.WriteLine("Windows registration cleanup failed. Check this installation's current-user Run/StartupApproved entry, Start menu shortcut, Pacer installation marker and notification activation registration. Remove only entries still owned by this installation.");
                    writer.WriteLine("Silent uninstall stops before application file removal. Interactive uninstall offers Retry, Continue uninstall or Cancel.");
                }
                WindowsInstallationIdentity.RequireNoReparse(path);
                File.Move(temporary, path, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch { Console.Error.WriteLine("Pacer could not save its cleanup report. See the uninstall log for manual cleanup instructions."); }
    }
}
