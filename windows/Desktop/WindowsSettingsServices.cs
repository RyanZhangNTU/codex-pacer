using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed record DesktopApplication(string Provider, string Name, string Family, string AppId, string? Executable = null);
internal sealed class WindowsDesktopApplications
{
    private static readonly DesktopApplication[] Known =
    [
        new("codex", "Codex", "OpenAI.Codex_2p2nqsd0c76g0", "App"),
        new("claude", "Claude", "Claude_pzs8sxrjxfjjc", "Claude")
    ];
    private readonly Func<string, bool> registered, activate;
    private readonly Func<string?> harnessPath;
    private readonly Func<string, bool> validateHarness, activateExecutable;
    private readonly WindowsConversationApplication conversations;
    internal static DesktopApplication? KnownApplication(string provider) => Known.FirstOrDefault(value => value.Provider == provider);
    private string? cachedHarness;
    private bool harnessScanned;
    private long nextHarnessScan;
    internal WindowsDesktopApplications(Func<string, bool>? registered = null, Func<string, bool>? activate = null,
        Func<string?>? harnessPath = null, Func<string, bool>? validateHarness = null, Func<string, bool>? activateExecutable = null,
        Func<string, Uri, Task<bool>>? activateProtocol = null, Func<Uri, Task<bool>>? activateWeb = null, Func<uint, ulong, bool>? activateHost = null)
    {
        this.registered = registered ?? Registered; this.activate = activate ?? Activate;
        var native = new Lazy<WindowsHarnessApplication>(() => new(Path.Combine(AppContext.BaseDirectory, "Engine")));
        this.harnessPath = harnessPath ?? (registered != null || activate != null ? () => null : () => native.Value.Locate());
        this.validateHarness = validateHarness ?? (path => native.Value.IsApplication(path));
        this.activateExecutable = activateExecutable ?? ActivateExecutable;
        bool injected = registered != null || activate != null;
        conversations = new(this.registered,
            activateProtocol ?? (injected ? (_, _) => Task.FromResult(false) : null),
            activateWeb ?? (injected ? _ => Task.FromResult(false) : null), activateHost ?? (injected ? (_, _) => false : null));
    }
    private string? Harness(bool fresh = false)
    {
        long now = Environment.TickCount64;
        if (!fresh && harnessScanned && now < nextHarnessScan) return cachedHarness;
        string? path = harnessPath(); cachedHarness = path != null && validateHarness(path) ? path : null;
        harnessScanned = true; nextHarnessScan = now + 60_000; return cachedHarness;
    }
    internal bool CanOpenHarness => Harness() != null;
    internal Task<bool> OpenConversationAsync(EngineNavigationPlan plan) => conversations.OpenAsync(plan);
    internal IReadOnlyList<DesktopApplication> Available()
    {
        var apps = Known.Where(value => registered(value.Family)).ToList();
        if (Harness() is string path) apps.Add(new("deepseek", "DeepSeek Harness", "", "", path));
        return apps;
    }
    internal bool Open(string provider)
    {
        if (provider == "deepseek") return Harness(fresh: true) is string path && activateExecutable(path);
        var app = Known.FirstOrDefault(value => value.Provider == provider);
        return app != null && registered(app.Family) && activate(app.Family + "!" + app.AppId);
    }
    private static bool ActivateExecutable(string path)
    {
        try { using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path)! }); return true; }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException) { return false; }
    }
    private static bool Registered(string family)
    {
        uint count = 0, size = 0;
        int result = GetPackagesByPackageFamily(family, ref count, IntPtr.Zero, ref size, IntPtr.Zero);
        return result == 122 && count is > 0 and <= 32 && size is > 0 and <= 65536;
    }
    private static bool Activate(string appId)
    {
        try { Process.Start(new ProcessStartInfo("shell:AppsFolder\\" + appId) { UseShellExecute = true }); return true; }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException) { return false; }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetPackagesByPackageFamily(string family, ref uint count, IntPtr names, ref uint length, IntPtr buffer);
}
