using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;

namespace CodexPacer.Windows;

internal static class WindowsNotificationCleanup
{
    internal static async Task<bool> UninstallAsync()
    {
        try
        {
            var store = new UserRegistrationStore();
            var own = NotificationRegistration.Find(Environment.ProcessPath!, store);
            if (own == null) return true;
            // Unknown additions can belong to another application or a user.
            // Fail before SDK UnregisterAll can delete their containing key.
            if (!Only(own.MappingKey, ["NotificationGUID"], 0) ||
                !Only(own.AppKey, ["DisplayName", "IconUri", "CustomActivator"], 0) ||
                !Only(own.ClassKey, [], 1) ||
                !Only(own.ClassKey + @"\LocalServer32", [""], 0) ||
                !AppNotificationManager.IsSupported()) return false;
            var manager = AppNotificationManager.Default;
            await manager.RemoveAllAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            try { manager.UnregisterAll(); }
            catch (COMException error) when (error.HResult is unchecked((int)0x80070002) or unchecked((int)0x80070003))
            {
                // A previous cleanup may have removed the native registration.
                // Verify below; never claim success while owned records remain.
            }
            using (var app = Registry.CurrentUser.OpenSubKey(own.AppKey))
                if (app != null) return false;
            using (var clsid = Registry.CurrentUser.OpenSubKey(own.ClassKey))
                if (clsid != null) return false;
            own.RemoveMapping(store);
            return store.Read(own.MappingKey, "NotificationGUID") == null;
        }
        catch (Exception error) when (WindowsStartupRegistration.Recoverable(error) || error is COMException or TimeoutException or ArgumentException)
        { return false; }
    }
    private static bool Only(string path, string[] allowed, int maximumSubkeys)
    {
        using var key = Registry.CurrentUser.OpenSubKey(path, false);
        return key == null || key.SubKeyCount <= maximumSubkeys &&
            key.GetValueNames().All(name => allowed.Contains(name, StringComparer.OrdinalIgnoreCase)) &&
            (maximumSubkeys == 0 || key.GetSubKeyNames().All(name => name == "LocalServer32"));
    }
}
