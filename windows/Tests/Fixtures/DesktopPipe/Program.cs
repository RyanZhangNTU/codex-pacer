#nullable enable
using System.Runtime.InteropServices;

// An isolated helper process: it holds one synthetic file open with the requested
// access until it is stopped, and exits at once without arguments. It never opens
// Codex, its data or any endpoint.
if (args.Length != 3) return 2;
string mode = args[0], file = args[1], ready = args[2];
if (mode is not ("file-read" or "file-write" or "file-append" or "file-write-private")) return 2;
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
try
{
    using var handle = new FileStream(file, mode == "file-append" ? FileMode.Append : FileMode.Open,
        mode == "file-read" ? FileAccess.Read : FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
    if (mode == "file-write-private" && !PrivateHolder.RestrictInspection()) return 1;
    File.WriteAllText(ready, "ready");
    await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token);
}
catch (Exception error) when (error is OperationCanceledException or IOException) { }
return 0;

internal static class PrivateHolder
{
    // The owner can query, wait for and stop this fixture, but cannot duplicate its handles.
    internal static bool RestrictInspection()
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW("D:(A;;0x101001;;;OW)", 1, out nint descriptor, out _)) return false;
        try { return SetKernelObjectSecurity(GetCurrentProcess(), 4, descriptor); }
        finally { LocalFree(descriptor); }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string text, uint revision, out nint descriptor, out uint size);
    [DllImport("advapi32.dll")]
    private static extern bool SetKernelObjectSecurity(nint handle, uint information, nint descriptor);
    [DllImport("kernel32.dll")]
    private static extern nint GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint memory);
}
