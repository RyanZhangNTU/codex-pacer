using System;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal static class WindowsProtocolLauncher
{
    internal static async Task<bool> OpenAsync(string family, Uri uri) => await global::Windows.System.Launcher.LaunchUriAsync(uri,
        new global::Windows.System.LauncherOptions { TargetApplicationPackageFamilyName = family, DisplayApplicationPicker = false });
    internal static async Task<bool> OpenWebAsync(Uri uri) => await global::Windows.System.Launcher.LaunchUriAsync(uri);
}
