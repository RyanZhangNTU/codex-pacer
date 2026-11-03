using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;

internal static class QaNotificationRegistration
{
    internal static void Remove(AppNotificationManager manager)
    {
        string executable = Path.GetFullPath(Environment.ProcessPath!);
        if (Path.GetFileNameWithoutExtension(executable) != "Pacer.NotificationProbe")
            throw new InvalidOperationException("Unexpected QA registration owner.");
        manager.UnregisterAll();
        // App SDK retains its path-to-AppId mapping after UnregisterAll.
        // Match P1a cleanup, but address only this separate QA executable.
        const string root = @"Software\Classes\AppUserModelId\";
        string path = root + executable.Replace('\\', '.');
        bool empty;
        using (var key = Registry.CurrentUser.OpenSubKey(path, true))
        {
            if (key == null) return;
            if (key.GetValue("NotificationGUID") is string appId)
            {
                if (!Guid.TryParseExact(appId, "B", out _)) throw new InvalidOperationException("Invalid QA path mapping.");
                using var remaining = Registry.CurrentUser.OpenSubKey(root + appId);
                if (remaining != null) throw new InvalidOperationException("The QA AppId registration was not removed.");
                key.DeleteValue("NotificationGUID", false);
            }
            empty = key.ValueCount == 0 && key.SubKeyCount == 0;
        }
        if (empty) Registry.CurrentUser.DeleteSubKey(path, false);
    }
}
