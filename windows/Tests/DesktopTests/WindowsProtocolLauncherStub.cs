using System;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// These process checks inject dispatch callbacks. Actual OS navigation belongs
/// to the WPF/installed-app checks, not a unit test's arbitrary URI handler.
internal static class WindowsProtocolLauncher
{
    internal static Task<bool> OpenAsync(string family, Uri uri) => throw new PlatformNotSupportedException("Inject protocol dispatch in desktop process checks.");
    internal static Task<bool> OpenWebAsync(Uri uri) => throw new PlatformNotSupportedException("Inject web dispatch in desktop process checks.");
}
