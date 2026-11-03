using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;

namespace CodexPacer.Windows;

/// The current Microsoft native notification API. Registration is lazy: demo
/// and capture sessions use an injected service and never register with the OS.
internal sealed class WindowsSystemNotifications(string iconPath, string displayName = "Codex Pacer", bool suppressDisplay = false, bool longDuration = false) : ISystemNotifications
{
    private AppNotificationManager? manager;
    private bool disposed;
    private string? lastActivation;
    private long lastActivationAt;
    public event Action<string>? Activated;
    internal event Action? Registered;
    public NotificationAvailability? CurrentAvailability
    {
        get
        {
            try { return manager == null ? null : manager.Setting switch
                { AppNotificationSetting.Enabled => NotificationAvailability.Available, AppNotificationSetting.Unsupported => NotificationAvailability.Unsupported, _ => NotificationAvailability.Denied }; }
            catch (Exception error) when (error is COMException or InvalidOperationException) { return NotificationAvailability.Failed; }
        }
    }
    public Task<NotificationAvailability> EnableAsync()
    {
        if (disposed) return Task.FromResult(NotificationAvailability.Failed);
        try
        {
            if (!WindowsPlatformPolicy.NotificationsSupported(Environment.OSVersion.Version.Build, () => AppNotificationManager.IsSupported())) return Task.FromResult(NotificationAvailability.Unsupported);
            if (manager == null)
            {
                var candidate = AppNotificationManager.Default;
                candidate.NotificationInvoked += Invoked;
                try { candidate.Register(displayName, new Uri(System.IO.Path.GetFullPath(iconPath))); }
                catch { candidate.NotificationInvoked -= Invoked; throw; }
                manager = candidate;
                Registered?.Invoke();
                var args = AppInstance.GetCurrent().GetActivatedEventArgs();
                if (args.Kind == ExtendedActivationKind.AppNotification && args.Data is AppNotificationActivatedEventArgs activated) Activate(activated.Argument);
            }
            return Task.FromResult(manager.Setting switch
            { AppNotificationSetting.Enabled => NotificationAvailability.Available, AppNotificationSetting.Unsupported => NotificationAvailability.Unsupported, _ => NotificationAvailability.Denied });
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException or System.IO.IOException or UnauthorizedAccessException)
        { return Task.FromResult(NotificationAvailability.Failed); }
    }
    private void Invoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) => Activate(args.Argument);
    private void Activate(string arguments)
    {
        string? action = NotificationPayload.ParseAction(arguments);
        if (action == null) return;
        long now = Environment.TickCount64;
        lock (this)
        {
            if (disposed || arguments == lastActivation && now - lastActivationAt < 1500) return;
            lastActivation = arguments; lastActivationAt = now;
        }
        Activated?.Invoke(arguments);
    }
    public bool Deliver(NotificationContent content)
    {
        try
        {
            if (disposed || manager?.Setting != AppNotificationSetting.Enabled) return false;
            var notification = new AppNotification(NotificationPayload.Xml(content, longDuration)) { Tag = NotificationPayload.Tag(content.Id), Group = "pacer", SuppressDisplay = suppressDisplay };
            manager.Show(notification); return notification.Id != 0;
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException or UnauthorizedAccessException) { return false; }
    }
    public async Task ClearAsync()
    {
        try { if (!disposed && manager != null) await manager.RemoveAllAsync(); }
        catch (Exception error) when (error is COMException or InvalidOperationException or UnauthorizedAccessException) { }
    }
    public async Task DisableAsync()
    {
        await ClearAsync(); Unregister();
    }
    private void Unregister()
    {
        if (manager == null) return;
        manager.NotificationInvoked -= Invoked;
        try { manager.Unregister(); } catch (Exception error) when (error is COMException or InvalidOperationException or UnauthorizedAccessException) { }
        manager = null;
    }
    public void Dispose() { if (disposed) return; disposed = true; Unregister(); }
}

internal sealed class DemoSystemNotifications : ISystemNotifications
{
    public event Action<string>? Activated { add { } remove { } }
    public Task<NotificationAvailability> EnableAsync() => Task.FromResult(NotificationAvailability.Available);
    public Task DisableAsync() => Task.CompletedTask;
    public Task ClearAsync() => Task.CompletedTask;
    public bool Deliver(NotificationContent content) => true;
    public void Dispose() { }
}
