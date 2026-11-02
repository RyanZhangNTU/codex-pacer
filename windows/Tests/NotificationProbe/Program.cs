using CodexPacer.Windows;
using Microsoft.Windows.AppNotifications;
using System.Text.Json;

internal static class Program
{
    [STAThread]
    private static async Task<int> Main(string[] args)
    {
        try { RecordActivationStart(args); return await RunAsync(args); }
        catch (Exception error)
        {
            Console.Error.WriteLine(JsonSerializer.Serialize(new { failure = error.GetType().Name, hresult = "0x" + error.HResult.ToString("X8"), message = error.Message }));
            return 1;
        }
    }

    private static void RecordActivationStart(string[] args)
    {
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) != "Pacer.NotificationProbe") return;
        string? mode = args.Contains("----AppNotificationActivated:") ? "cold-activation" :
            args.Length == 1 && args[0] is "--warm" or "--interactive" or "--prepare-cold" or "--cleanup" or "--invoke-show" or "--invoke-snooze" ? args[0][2..] : null;
        if (mode == null) return;
        string path = Path.Combine(AppContext.BaseDirectory, "notification-activation.start.jsonl");
        try
        {
            if (File.Exists(path) && new FileInfo(path).Length > 64 * 1024) File.WriteAllText(path, "");
            File.AppendAllText(path, JsonSerializer.Serialize(new { processId = Environment.ProcessId, at = DateTimeOffset.UtcNow, mode }) + "\n");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 1 && args[0] is "--invoke-show" or "--invoke-snooze") { NativeActivationInvoker.Invoke(args[0] == "--invoke-show" ? "showIsland" : "snoozeSpike"); return 0; }
        if (args.Any(value => value == "----AppNotificationActivated:")) return await ActivationCheck.RunAsync("cold-activation");
        if (args.Length == 1 && args[0] is "--warm" or "--interactive" or "--prepare-cold" or "--cleanup") return await ActivationCheck.RunAsync(args[0][2..]);
        if (args.Length > 1 || args.Length == 1 && args[0] != "--native") throw new ArgumentException("Use --native for the isolated delivery check.");
        bool supported = AppNotificationManager.IsSupported();
        if (args.Length == 0) { Console.WriteLine(JsonSerializer.Serialize(new { supported, registration = "untouched" })); return 0; }
        // UnregisterAll below belongs exclusively to this separate executable,
        // never to CodexPacer's saved notification identity or history.
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) != "Pacer.NotificationProbe") throw new InvalidOperationException("Unexpected probe process identity.");
        if (!supported) { Console.WriteLine("Native notifications are unsupported in this session."); return 2; }
        using var system = new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), "Codex Pacer notification QA", suppressDisplay: true);
        var manager = AppNotificationManager.Default;
        try
        {
            var availability = await system.EnableAsync();
            if (availability != NotificationAvailability.Available) throw new InvalidOperationException("Native notification availability: " + availability);
            var content = new NotificationContent("pacer-isolated-native-qa", "Codex Pacer QA", "Synthetic notification delivery check.", [new("snoozeSpike", "Not for an Hour")]);
            if (!system.Deliver(content)) throw new InvalidOperationException("The native SDK did not accept the notification.");
            var history = await manager.GetAllAsync();
            bool verified = history.Any(value => value.Tag == NotificationPayload.Tag(content.Id) && value.Group == "pacer" && value.Id != 0);
            if (!verified) throw new InvalidOperationException("The synthetic entry was not found in its own notification history.");
            Console.WriteLine(JsonSerializer.Serialize(new { supported, suppressed = true, nativeDelivery = true, ownHistoryVerified = verified }));
            return 0;
        }
        finally
        {
            try { await manager.RemoveAllAsync(); }
            finally { system.Dispose(); manager.UnregisterAll(); }
            Console.WriteLine("The separate QA history and registration were removed.");
        }
    }
}
