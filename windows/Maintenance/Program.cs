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
                case "uninstall" when args.Length == 3: await operations.UninstallAsync(deadline.Token); break;
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
}
