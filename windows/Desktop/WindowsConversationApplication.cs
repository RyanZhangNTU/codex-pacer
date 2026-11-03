using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// Protocol launches target the registered provider package, rather than an
/// arbitrary default handler. Host capabilities stay inside the engine.
internal sealed class WindowsConversationApplication
{
    private readonly Func<string, bool> registered;
    private readonly Func<string, Uri, Task<bool>> protocol;
    private readonly Func<Uri, Task<bool>> web;
    private readonly Func<uint, ulong, bool> host;
    internal WindowsConversationApplication(Func<string, bool> registered,
        Func<string, Uri, Task<bool>>? protocol = null, Func<Uri, Task<bool>>? web = null, Func<uint, ulong, bool>? host = null)
    {
        this.registered = registered; this.protocol = protocol ?? WindowsProtocolLauncher.OpenAsync; this.web = web ?? WindowsProtocolLauncher.OpenWebAsync;
        this.host = host ?? ((pid, started) => HostActivate.Value(pid, started) == 1);
    }
    private static readonly Lazy<ActivateHost> HostActivate = new(() => NativeMotion.SharedExport<ActivateHost>(
        Path.Combine(AppContext.BaseDirectory, "Engine"), "pacer_host_window_activate"));
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ActivateHost(uint pid, ulong started);

    internal async Task<bool> OpenAsync(EngineNavigationPlan plan)
    {
        if (!Guid.TryParse(plan.Context, out _) || plan.Provider is not ("claude" or "codex")) return false;
        try
        {
            if (plan.Kind == "terminal") return await WindowsSshTerminal.OpenAsync(plan);
            if (plan.Kind == "wslTerminal") return await WindowsWslTerminal.OpenAsync(plan);
            if (plan.Terminal != null) return false;
            if (plan.Kind == "host") return plan.Url == null && plan.WebUrl == null && plan.Pid is > 0 && plan.Started is > 0 && host(plan.Pid.Value, plan.Started.Value);
            if (plan.Kind != "application" || plan.Pid != null || plan.Started != null || !TryDestination(plan.Provider, plan.Url, plan.WebUrl, out Uri? uri, out Uri? fallback)) return false;
            var app = WindowsDesktopApplications.KnownApplication(plan.Provider);
            try { if (app != null && registered(app.Family) && await protocol(app.Family, uri!)) return true; }
            catch (Exception error) when (Recoverable(error)) { }
            return fallback != null && await web(fallback);
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }
    internal static bool IsHostPlan(EngineNavigationPlan plan) => Guid.TryParse(plan.Context, out _) && plan.Provider is "claude" or "codex"
        && plan.Kind == "host" && plan.Url == null && plan.WebUrl == null && plan.Terminal == null && plan.Pid is > 0 && plan.Started is > 0;
    internal static bool TryDestination(string provider, string? value, string? fallbackValue, out Uri? uri, out Uri? fallback)
    {
        uri = null; fallback = null;
        if (value == null || value.Length > 2048 || !Uri.TryCreate(value, UriKind.Absolute, out var candidate) ||
            !string.IsNullOrEmpty(candidate.UserInfo) || candidate.Port != -1 || !string.IsNullOrEmpty(candidate.Fragment)) return false;
        string? key = null, argument = null;
        if (candidate.Query.Length > 0)
        {
            var pair = candidate.Query[1..].Split('=');
            if (pair.Length != 2 || pair[0].Length == 0 || pair[1].Contains('&')) return false;
            key = pair[0]; argument = Uri.UnescapeDataString(pair[1]);
            if (argument.Length > 256) return false;
        }
        if (provider == "codex")
        {
            if (candidate.Scheme != "codex" || candidate.Host != "threads" || !candidate.AbsolutePath.StartsWith("/", StringComparison.Ordinal) || !Guid.TryParseExact(candidate.AbsolutePath[1..], "D", out _) ||
                (key != null && (key != "hostId" || !Regex.IsMatch(argument!, @"\Aremote-(?:ssh-discovered:[A-Za-z0-9][A-Za-z0-9._-]{0,128}|control:[A-Za-z0-9_-]{1,128})\z"))) || fallbackValue != null) return false;
        }
        else if (provider == "claude")
        {
            if (candidate.Scheme != "claude" || candidate.Host != "code") return false;
            if (candidate.AbsolutePath == "/continue")
            {
                if (key != "session" || argument?.StartsWith("local_", StringComparison.Ordinal) != true ||
                    !Guid.TryParseExact(argument[6..], "D", out _) || fallbackValue != null) return false;
            }
            else
            {
                if (!Regex.IsMatch(Uri.UnescapeDataString(candidate.AbsolutePath), @"\A/project/chan_\w{6,120}\z", RegexOptions.CultureInvariant) ||
                    (key != null && (key != "thread" || !Regex.IsMatch(argument!, @"\A(?:cmsg|session|ses|cse)_\w{6,120}\z", RegexOptions.CultureInvariant) || argument!.StartsWith("cmsg_pending_", StringComparison.Ordinal)))) return false;
                if (fallbackValue != null)
                {
                    var expected = new Uri("https://claude.ai/code" + candidate.AbsolutePath + candidate.Query);
                    if (!Uri.TryCreate(fallbackValue, UriKind.Absolute, out fallback) || fallback.AbsoluteUri != expected.AbsoluteUri) return false;
                }
            }
        }
        else return false;
        uri = candidate; return true;
    }
    private static bool Recoverable(Exception error) => error is COMException or Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException or ArgumentException;
}
