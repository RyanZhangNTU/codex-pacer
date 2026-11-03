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
        if (Path.GetFileNameWithoutExtension(executable) != "Pacer.NotificationProbe" || !NotificationPayload.IsAction(action))
            throw new InvalidOperationException("Unexpected QA invocation.");
        using var threadIdentity = System.Security.Principal.WindowsIdentity.GetCurrent(true);
        Record(new { phase = "client-start", action, processId = Environment.ProcessId, parents = Parents(), inJob = InJob(),
            architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            tokenElevation = TokenFlag(20), tokenHasRestrictions = TokenFlag(21), restrictedSids = HasRestrictedSids(), appContainer = TokenFlag(29),
            impersonating = threadIdentity != null, integrity = Integrity(), uiAccess = TokenFlag(26), session = TokenFlag(12), packaged = HasPackageIdentity(),
            sameInteractiveUser = SameInteractiveUser() });
        string ownIcon = Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico");
        var candidates = new List<(string AppId, Guid Activator)>();
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Classes\AppUserModelId");
        int displayMatches = 0, iconMatches = 0;
        foreach (string name in root?.GetSubKeyNames() ?? [])
        {
            using var key = root!.OpenSubKey(name);
            if (key?.GetValue("DisplayName") is not "Codex Pacer notification QA") continue;
            displayMatches++;
            if (key.GetValue("IconUri") is not string icon || !SamePath(icon, ownIcon)) continue;
            iconMatches++;
            if (key.GetValue("CustomActivator") is not string clsid || !Guid.TryParse(clsid, out var activator)) continue;
            using var server = Registry.CurrentUser.OpenSubKey(@"Software\Classes\CLSID\" + activator.ToString("B") + @"\LocalServer32");
            if (server?.GetValue("") is not string command || !command.EndsWith("\" ----AppNotificationActivated:", StringComparison.Ordinal)
                || !SamePath(command.Trim()[1..^"\" ----AppNotificationActivated:".Length], executable))
                throw new InvalidOperationException("The QA COM server does not point to the expected probe executable.");
            candidates.Add((name, activator));
        }
        Record(new { phase = "candidate-count", action, displayMatches, iconMatches, count = candidates.Count });
        if (candidates.Count != 1) throw new InvalidOperationException("Exactly one owned QA registration is required.");
        var candidate = candidates.Single();
        using (var merged = Registry.ClassesRoot.OpenSubKey(@"CLSID\" + candidate.Activator.ToString("B") + @"\LocalServer32"))
            Record(new { phase = "owned-com-lookup", action, processId = Environment.ProcessId, parent = Parent(), inJob = InJob(),
                architecture = RuntimeInformation.ProcessArchitecture.ToString(), mergedClassPresent = merged?.GetValue("") is string,
                tokenElevation = TokenFlag(20), tokenFiltered = TokenFlag(21), restrictedSids = HasRestrictedSids(), appContainer = TokenFlag(29),
                impersonating = threadIdentity != null, integrity = Integrity(), uiAccess = TokenFlag(26), session = TokenFlag(12), packaged = HasPackageIdentity(),
                elevated = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent())
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) });
        int initialized = CoInitializeEx(IntPtr.Zero, 0);
        if (initialized < 0 && initialized != unchecked((int)0x80010106)) Marshal.ThrowExceptionForHR(initialized);
        try
        {
            Guid clsid = candidate.Activator, iid = typeof(INotificationActivationCallback).GUID;
            int created = CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out var pointer);
            Record(new { phase = "create-result", action, hresult = "0x" + created.ToString("X8") });
            Marshal.ThrowExceptionForHR(created);
            object callback;
            try { callback = Marshal.GetObjectForIUnknown(pointer); }
            finally { Marshal.Release(pointer); }
            try { Marshal.ThrowExceptionForHR(((INotificationActivationCallback)callback).Activate(candidate.AppId, ActivationCheck.ArgumentsFor(action), IntPtr.Zero, 0)); }
            finally { Marshal.FinalReleaseComObject(callback); }
        }
        finally { if (initialized >= 0) CoUninitialize(); }
        Console.WriteLine("The owned QA COM activation was accepted.");
    }
    private static void Record(object value)
    {
        string json = System.Text.Json.JsonSerializer.Serialize(value);
        Console.WriteLine(json);
        string path = Path.Combine(AppContext.BaseDirectory, "notification-client.diagnostics.jsonl");
        if (File.Exists(path) && new FileInfo(path).Length > 64 * 1024) File.WriteAllText(path, "");
        File.AppendAllText(path, json + "\n");
    }
    private static bool? InJob() => IsProcessInJob(new IntPtr(-1), IntPtr.Zero, out bool value) ? value : null;
    private static bool SamePath(string left, string right) => string.Equals(LongPath(left), LongPath(right), StringComparison.OrdinalIgnoreCase);
    private static string LongPath(string path)
    {
        var buffer = new System.Text.StringBuilder(32768);
        return GetLongPathName(Path.GetFullPath(path), buffer, (uint)buffer.Capacity) is > 0 and < 32768 ? buffer.ToString() : Path.GetFullPath(path);
    }
    private static string[] Parents()
    {
        var names = new List<string>(); int current = Environment.ProcessId;
        for (int i = 0; i < 10; i++)
        {
            try
            {
                using var process = System.Diagnostics.Process.GetProcessById(current);
                if (NtQueryInformationProcess(process.Handle, 0, out var value, Marshal.SizeOf<ProcessBasic>(), out _) < 0 || value.Parent == IntPtr.Zero) break;
                current = value.Parent.ToInt32();
                using var parent = System.Diagnostics.Process.GetProcessById(current); names.Add(parent.ProcessName);
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { break; }
        }
        return names.ToArray();
    }
    private static bool? SameInteractiveUser()
    {
        using var current = System.Security.Principal.WindowsIdentity.GetCurrent();
        foreach (var process in System.Diagnostics.Process.GetProcessesByName("explorer"))
        {
            using (process)
            {
                if (process.SessionId != TokenFlag(12)) continue;
                if (!OpenProcessToken(process.Handle, 8, out var token)) continue;
                using (token) using (var identity = new System.Security.Principal.WindowsIdentity(token.DangerousGetHandle())) return current.User == identity.User;
            }
        }
        return null;
    }
    private static string Parent()
    {
        if (NtQueryInformationProcess(new IntPtr(-1), 0, out var value, Marshal.SizeOf<ProcessBasic>(), out _) < 0) return "unknown";
        try { return System.Diagnostics.Process.GetProcessById(value.Parent.ToInt32()).ProcessName; } catch (ArgumentException) { return "exited"; }
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessBasic { internal IntPtr Reserved, Peb, Affinity, Priority, Id, Parent; }
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool value);
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr process, int kind, out ProcessBasic value, int length, out int returned);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetLongPathNameW")]
    private static extern uint GetLongPathName(string path, System.Text.StringBuilder value, uint length);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token);

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
    private static string Integrity()
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        IntPtr buffer = Marshal.AllocHGlobal(1024);
        try
        {
            if (!GetTokenBuffer(identity.AccessToken, 25, buffer, 1024, out _)) return "unknown";
            IntPtr sid = Marshal.ReadIntPtr(buffer); int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            int value = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
            return value < 0x2000 ? "low" : value < 0x3000 ? "medium" : value < 0x4000 ? "high" : "system";
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static bool HasPackageIdentity() { uint length = 0; return GetCurrentPackageFullName(ref length, IntPtr.Zero) != 15700; }
    [DllImport("kernel32.dll")] private static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);
    [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetTokenBuffer(Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token, int information, IntPtr value, int length, out int required);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
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
