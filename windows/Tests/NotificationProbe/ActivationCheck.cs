using CodexPacer.Windows;
using Microsoft.Windows.AppNotifications;
using System.Text.Json;

/// Interactive evidence belongs to this QA executable, not the app's saved
/// preferences or notification identity. No task or account data is loaded.
internal static class ActivationCheck
{
    private sealed record Pending(string Mode, DateTimeOffset CreatedAt, string Nonce);
    private static readonly string PendingPath = Path.Combine(AppContext.BaseDirectory, "notification-activation.pending.json");
    private static readonly string ResultPath = Path.Combine(AppContext.BaseDirectory, "notification-activation.result.json");

    internal static async Task<int> RunAsync(string mode)
    {
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) != "Pacer.NotificationProbe") throw new InvalidOperationException("Unexpected probe process identity.");
        using var instance = new Mutex(true, "Local\\Pacer.NotificationProbe.ActivationQA", out bool first);
        if (!first) throw new InvalidOperationException("A QA notification probe is already running.");
        if (mode != "cleanup" && !AppNotificationManager.IsSupported()) throw new InvalidOperationException("Native notifications are unsupported in this session.");
        Pending? pending = null;
        if (mode == "cold-activation")
        {
            if (!File.Exists(PendingPath) || new FileInfo(PendingPath).Length > 1024) return 2;
            pending = JsonSerializer.Deserialize<Pending>(File.ReadAllText(PendingPath));
            if (pending?.Mode != "cold" || pending.CreatedAt > DateTimeOffset.UtcNow || DateTimeOffset.UtcNow - pending.CreatedAt > TimeSpan.FromMinutes(5)) return 2;
        }
        else if (mode != "cleanup")
        {
            pending = new(mode == "prepare-cold" ? "cold" : "warm", DateTimeOffset.UtcNow, Guid.NewGuid().ToString("N"));
            File.WriteAllText(PendingPath, JsonSerializer.Serialize(pending)); File.Delete(ResultPath);
        }
        bool keepForColdActivation = false;
        using var system = new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), "Codex Pacer notification QA", suppressDisplay: mode != "interactive");
        var activated = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        system.Activated += value => activated.TrySetResult(value);
        var manager = AppNotificationManager.Default;
        try
        {
            var availability = await system.EnableAsync();
            if (mode == "cleanup") return 0;
            if (availability != NotificationAvailability.Available) throw new InvalidOperationException("Native notification availability: " + availability);
            if (mode != "cold-activation")
            {
                var content = new NotificationContent("pacer-isolated-activation-qa", "Codex Pacer QA",
                    mode == "prepare-cold" ? "Synthetic cold-start check. Select this notification after the QA process exits." : "Synthetic button check. The button only records the QA action.",
                    [new("snoozeSpike", "Verify QA action")]);
                if (!system.Deliver(content)) throw new InvalidOperationException("The native SDK did not accept the QA notification.");
                Console.WriteLine(JsonSerializer.Serialize(new { phase = "ready", mode, processId = Environment.ProcessId })); Console.Out.Flush();
                if (mode == "prepare-cold") { keepForColdActivation = true; return 0; }
            }
            string action = await activated.Task.WaitAsync(TimeSpan.FromSeconds(mode == "cold-activation" ? 20 : 120));
            var result = new { mode, action, processId = Environment.ProcessId, pending!.Nonce, nativeCallback = true };
            File.WriteAllText(ResultPath, JsonSerializer.Serialize(result)); Console.WriteLine(JsonSerializer.Serialize(result));
            return 0;
        }
        finally
        {
            if (!keepForColdActivation)
            {
                try { await manager.RemoveAllAsync(); }
                finally { system.Dispose(); manager.UnregisterAll(); File.Delete(PendingPath); }
                Console.WriteLine("The separate QA history and registration were removed.");
            }
        }
    }
}
