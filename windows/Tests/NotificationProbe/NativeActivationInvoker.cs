using CodexPacer.Windows;
using Microsoft.Win32;
using System.Runtime.InteropServices;

/// Uses the documented Windows SDK callback interface against this probe's
/// own COM registration. This verifies native routing, not banner UI clicks.
internal static class NativeActivationInvoker
{
    internal static void Invoke(string action)
    {
        string executable = Path.GetFullPath(Environment.ProcessPath!);
        if (Path.GetFileNameWithoutExtension(executable) != "Pacer.NotificationProbe" || action is not ("showIsland" or "snoozeSpike"))
            throw new InvalidOperationException("Unexpected QA invocation.");
        string ownIcon = Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico");
        var candidates = new List<(string AppId, Guid Activator)>();
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Classes\AppUserModelId");
        foreach (string name in root?.GetSubKeyNames() ?? [])
        {
            using var key = root!.OpenSubKey(name);
            if (key?.GetValue("DisplayName") is not "Codex Pacer notification QA" || key.GetValue("IconUri") is not string icon
                || !string.Equals(Path.GetFullPath(icon), Path.GetFullPath(ownIcon), StringComparison.OrdinalIgnoreCase)
                || key.GetValue("CustomActivator") is not string clsid || !Guid.TryParse(clsid, out var activator)) continue;
            using var server = Registry.CurrentUser.OpenSubKey(@"Software\Classes\CLSID\" + activator.ToString("B") + @"\LocalServer32");
            if (server?.GetValue("") is not string command || !string.Equals(command.Trim(), "\"" + executable + "\" ----AppNotificationActivated:", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The QA COM server does not point to the expected probe executable.");
            candidates.Add((name, activator));
        }
        if (candidates.Count != 1) throw new InvalidOperationException("Exactly one owned QA registration is required.");
        var candidate = candidates.Single();
        using var threadIdentity = System.Security.Principal.WindowsIdentity.GetCurrent(true);
        using (var merged = Registry.ClassesRoot.OpenSubKey(@"CLSID\" + candidate.Activator.ToString("B") + @"\LocalServer32"))
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { phase = "owned-com-lookup", action,
                architecture = RuntimeInformation.ProcessArchitecture.ToString(), mergedClassPresent = merged?.GetValue("") is string,
                tokenElevation = TokenFlag(20), tokenFiltered = TokenFlag(21), restrictedSids = HasRestrictedSids(), appContainer = TokenFlag(29),
                impersonating = threadIdentity != null,
                elevated = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent())
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) }));
        int initialized = CoInitializeEx(IntPtr.Zero, 0);
        if (initialized < 0 && initialized != unchecked((int)0x80010106)) Marshal.ThrowExceptionForHR(initialized);
        try
        {
            Guid clsid = candidate.Activator, iid = typeof(INotificationActivationCallback).GUID;
            Marshal.ThrowExceptionForHR(CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out var pointer));
            object callback;
            try { callback = Marshal.GetObjectForIUnknown(pointer); }
            finally { Marshal.Release(pointer); }
            try { Marshal.ThrowExceptionForHR(((INotificationActivationCallback)callback).Activate(candidate.AppId, NotificationPayload.Argument(action), IntPtr.Zero, 0)); }
            finally { Marshal.FinalReleaseComObject(callback); }
        }
        finally { if (initialized >= 0) CoUninitialize(); }
        Console.WriteLine("The owned QA COM activation was accepted.");
    }

    private static int? TokenFlag(int information)
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        return GetTokenInformation(identity.AccessToken, information, out int value, sizeof(int), out _) ? value : null;
    }
    private static bool HasRestrictedSids()
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        return IsTokenRestricted(identity.AccessToken);
    }
    [DllImport("advapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsTokenRestricted(Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token, int information,
        out int value, int length, out int required);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(IntPtr reserved, uint concurrency);
    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern void CoUninitialize();
    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, out IntPtr instance);

    // Windows SDK um/NotificationActivationCallback.idl; no user input data.
    [ComImport, Guid("53E31837-6600-4A81-9395-75CFFE746F94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface INotificationActivationCallback
    {
        [PreserveSig]
        int Activate([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string invokedArgs, IntPtr data, uint count);
    }
}
