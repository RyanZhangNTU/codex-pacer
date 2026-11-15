using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// Protocol launches target the registered provider package, rather than an
/// arbitrary default handler. Host capabilities stay inside the engine.
internal sealed class WindowsConversationApplication
{
    private readonly Func<string, bool> registered;
    private readonly Func<string, Uri, Task<bool>> protocol;
    private readonly Func<Uri, Task<bool>> web;
    private readonly Func<uint, ulong, bool> host;
    private readonly Func<string, Uri, bool> signedHandler;
    private sealed record SignedHandler(string Scheme, string Publisher, string[] ProgramFiles, string[] UserPrograms, string? ConnectorsPath);
    // Modules that open through their own URL scheme come from the engine's
    // registry; the handler must still carry the declared signer.
    private static volatile IReadOnlyDictionary<string, SignedHandler> SignedHandlers = new Dictionary<string, SignedHandler>(StringComparer.Ordinal);
    internal static void Register(IEnumerable<EngineModule>? modules)
    {
        var next = new Dictionary<string, SignedHandler>(StringComparer.Ordinal);
        foreach (var module in modules ?? [])
        {
            if (module.Launch is not { } launch || !DesktopPreferences.ValidProviderId(module.Provider)
                || !Regex.IsMatch(launch.Scheme, "^[a-z][a-z0-9+.-]{0,31}$") || launch.Publisher.Length is 0 or > 256) continue;
            string[] paths = launch.Executables.Where(path => path.Length is > 0 and <= 260 && !Path.IsPathRooted(path) && !path.Contains(".."))
                .Select(path => path.Replace('/', '\\')).ToArray();
            if (paths.Length == 0) continue;
            string? connectors = launch.ConnectorsPath is { } value && Regex.IsMatch(value, "^[a-z][a-z0-9/-]{0,63}$") ? value : null;
            next[module.Provider] = new(launch.Scheme, launch.Publisher, paths, paths, connectors);
        }
        if (!next.Keys.Order().SequenceEqual(SignedHandlers.Keys.Order()) || next.Any(pair => !SignedHandlers.TryGetValue(pair.Key, out var known)
            || known.Scheme != pair.Value.Scheme || known.Publisher != pair.Value.Publisher || known.ConnectorsPath != pair.Value.ConnectorsPath
            || !known.ProgramFiles.SequenceEqual(pair.Value.ProgramFiles))) SignedHandlers = next;
    }
    internal static bool CanOpenApplication(string provider) => SignedHandlers.ContainsKey(provider);
    internal static bool CanOpenConnectors(string provider) => SignedHandlers.TryGetValue(provider, out var handler) && handler.ConnectorsPath != null;

    internal static Task<bool> OpenApplicationAsync(string provider) => OpenProviderAsync(provider, null);

    internal static Task<bool> OpenProgressConnectorsAsync(string provider) => SignedHandlers.TryGetValue(provider, out var handler) && handler.ConnectorsPath != null
        ? OpenProviderAsync(provider, new Uri(handler.Scheme + "://" + handler.ConnectorsPath)) : Task.FromResult(false);

    private static async Task<bool> OpenProviderAsync(string provider, Uri? destination)
    {
        if (!SignedHandlers.TryGetValue(provider, out var application)) return false;
        try { return await Task.Run(() => OpenSignedHandler(application, destination)); }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }

    internal enum RestartResult { Restarted, StillRunning, Failed }

    /// Closes the app and starts it at its connectors.
    ///
    /// WorkBuddy quits only from its tray menu: closing its window or the end-of-
    /// session messages (the Restart Manager's request, which waits 30 seconds
    /// and fails) only hide it in the tray. So Pacer ends its processes, which
    /// its crash recovery is built for. The card asks first while a task runs.
    internal static async Task<RestartResult> RestartForGuideAsync(string provider, IReadOnlyList<string> executables)
    {
        if (!SignedHandlers.ContainsKey(provider)) return RestartResult.Failed;
        try
        {
            bool quit = await Task.Run(async () =>
            {
                string[] names = executables.Select(path => Path.GetFileNameWithoutExtension(path.Replace('/', '\\'))).Where(name => name.Length > 0)
                    .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                var processes = names.SelectMany(Process.GetProcessesByName).ToArray();
                try
                {
                    // The earliest process is the app itself; its helpers go with it.
                    var main = processes.Select(process => { try { return (process, started: process.StartTime); } catch (Exception error) when (Recoverable(error)) { return (process, started: DateTime.MaxValue); } })
                        .OrderBy(entry => entry.started).Select(entry => entry.process).FirstOrDefault();
                    try { main?.Kill(entireProcessTree: true); }
                    catch (Exception error) when (Recoverable(error) || error is NotSupportedException) { }
                }
                finally { foreach (var process in processes) process.Dispose(); }
                for (int wait = 0; wait < 40; wait++)
                {
                    if (!names.Any(name => { var left = Process.GetProcessesByName(name); bool any = left.Length > 0; foreach (var p in left) p.Dispose(); return any; })) return true;
                    await Task.Delay(250);
                }
                return false;
            });
            if (!quit) return RestartResult.StillRunning;
            return await OpenProgressConnectorsAsync(provider) ? RestartResult.Restarted : RestartResult.Failed;
        }
        catch (Exception error) when (Recoverable(error)) { return RestartResult.Failed; }
    }

    /// Waits for the user to quit the app after it declined Pacer's request.
    internal static async Task<bool> WaitForExitAsync(IReadOnlyList<string> executables, TimeSpan timeout)
    {
        string[] names = executables.Select(path => Path.GetFileNameWithoutExtension(path.Replace('/', '\\'))).Where(name => name.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (!names.Any(name => { var left = Process.GetProcessesByName(name); bool any = left.Length > 0; foreach (var p in left) p.Dispose(); return any; })) return true;
            await Task.Delay(500);
        }
        return false;
    }

    internal WindowsConversationApplication(Func<string, bool> registered,
        Func<string, Uri, Task<bool>>? protocol = null, Func<Uri, Task<bool>>? web = null, Func<uint, ulong, bool>? host = null,
        Func<string, Uri, bool>? signedHandler = null)
    {
        this.registered = registered; this.protocol = protocol ?? WindowsProtocolLauncher.OpenAsync; this.web = web ?? WindowsProtocolLauncher.OpenWebAsync;
        this.host = host ?? ((pid, started) => HostActivate.Value(pid, started) == 1);
        this.signedHandler = signedHandler ?? ((provider, uri) => SignedHandlers.TryGetValue(provider, out var handler) && OpenSignedHandler(handler, uri));
    }
    private static readonly Lazy<ActivateHost> HostActivate = new(() => NativeMotion.SharedExport<ActivateHost>(
        Path.Combine(AppContext.BaseDirectory, "Engine"), "pacer_host_window_activate"));
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ActivateHost(uint pid, ulong started);

    internal async Task<bool> OpenAsync(EngineNavigationPlan plan)
    {
        if (!Guid.TryParse(plan.Context, out _)) return false;
        try
        {
            if (SignedHandlers.ContainsKey(plan.Provider))
                return plan.Kind == "application" && plan.Pid == null && plan.Started == null && plan.Terminal == null &&
                    TryDestination(plan.Provider, plan.Url, plan.WebUrl, out var target, out _) &&
                    await Task.Run(() => signedHandler(plan.Provider, target!));
            if (plan.Provider is not ("claude" or "codex")) return false;
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
                (key != null && (key != "hostId" || !Regex.IsMatch(argument!, @"\A(?:durable|remote-(?:ssh-discovered:[A-Za-z0-9][A-Za-z0-9._-]{0,128}|control:[A-Za-z0-9_-]{1,128}))\z"))) || fallbackValue != null) return false;
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
        else if (SignedHandlers.TryGetValue(provider, out var application))
        {
            if (candidate.Scheme != application.Scheme || candidate.Host != "chat" || candidate.Query.Length != 0 ||
                fallbackValue != null || candidate.AbsolutePath.Length != 37 ||
                !Guid.TryParseExact(candidate.AbsolutePath[1..], "D", out var session) ||
                value != application.Scheme + "://chat/" + session.ToString("D")) return false;
        }
        else return false;
        uri = candidate; return true;
    }

    private static bool OpenSignedHandler(SignedHandler application, Uri? uri)
    {
        using var key = Registry.ClassesRoot.OpenSubKey(application.Scheme + @"\shell\open\command");
        if (key?.GetValue(null) is not string registeredCommand) return false;
        var handler = Regex.Match(registeredCommand, "\\A\"([^\"\\r\\n]+)\" \"%1\"\\z", RegexOptions.CultureInvariant);
        if (!handler.Success) return false;
        string path = Path.GetFullPath(handler.Groups[1].Value);
        bool Matches(Environment.SpecialFolder folder, string[] names)
        {
            string root = Environment.GetFolderPath(folder);
            return root.Length != 0 && Array.Exists(names, name => StringComparer.OrdinalIgnoreCase.Equals(path, Path.Combine(root, name)));
        }
        bool installed = Matches(Environment.SpecialFolder.ProgramFiles, application.ProgramFiles) ||
            Matches(Environment.SpecialFolder.LocalApplicationData, application.UserPrograms);
        if (!installed || !File.Exists(path) || !UpdateAuthenticode.VerifySigner(path, encoded =>
        {
            using var signer = X509CertificateLoader.LoadCertificate(encoded);
            return signer.GetNameInfo(X509NameType.SimpleName, false) == application.Publisher;
        })) return false;
        var start = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(path)! };
        if (uri != null) start.ArgumentList.Add(uri.AbsoluteUri);
        using var process = Process.Start(start);
        return process != null;
    }
    private static bool Recoverable(Exception error) => error is COMException or Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException or ArgumentException or CryptographicException;
}
