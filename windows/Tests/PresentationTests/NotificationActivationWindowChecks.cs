using System;
using System.Threading.Tasks;
using System.Windows;
using CodexPacer.Windows;

internal static class NotificationActivationWindowChecks
{
    internal static async Task Run()
    {
        var scope = Guid.NewGuid();
        var window = new Window { Width = 160, Height = 80, Opacity = 0, ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
        WindowRendering.Prepare(window);
        int regular = 0; var received = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var activation = new WindowsInstanceActivation(window, _ => regular++, scope, notificationActivated: value => received.TrySetResult(value));
        try
        {
            window.Show();
            string arguments = NotificationPayload.Argument("openTask", new string('a', 32));
            Check(await Task.Run(() => WindowsInstanceActivation.TryActivateNotification(arguments, scope)), "A second instance must forward its bounded reference to the marked HWND");
            Check(await received.Task.WaitAsync(TimeSpan.FromSeconds(1)) == arguments && regular == 0, "Notification forwarding preserves only the reference and cannot become a Show or Settings command");
            Check(!WindowsInstanceActivation.TryActivateNotification(arguments + "&url=untrusted", scope), "Extra activation fields are rejected before native IPC");
            Check(!WindowsInstanceActivation.TryActivateNotification("pacer=1&action=topUp", scope), "Old unscoped notification arguments cannot cross instances");
            Console.WriteLine("PASS notification instance routing: bounded refs, native HWND delivery and rejected legacy/extra fields");
        }
        finally { window.Close(); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
