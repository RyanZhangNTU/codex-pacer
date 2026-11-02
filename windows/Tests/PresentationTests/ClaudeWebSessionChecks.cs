using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;
using Microsoft.Web.WebView2.Core;

internal static class ClaudeWebSessionChecks
{
    private const string Key = "synthetic-claude-session-00000000", Organization = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    internal static async Task Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-claude-web-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); var site = new Site();
        var session = new ClaudeWebSession(UiText.For(false), Path.Combine(root, "Claude"), site.Bind, false);
        try
        {
            Check(session.Available, "Claude needs the pinned stable WebView2 runtime for its isolated fixture");
            Check(await session.ReadAsync(CancellationToken.None) == null, "An empty private profile cannot appear signed in");
            var signingIn = session.SignInAsync(); await Until(() => { if (signingIn.IsFaulted) signingIn.GetAwaiter().GetResult(); return Application.Current.Windows.OfType<ClaudeLoginWindow>().Any() && site.Ready; });
            var window = Application.Current.Windows.OfType<ClaudeLoginWindow>().Single(); window.IsHitTestVisible = false;
            Check(Math.Abs(window.ClientContent.ActualWidth - Math.Min(760, Math.Max(420, SystemParameters.WorkArea.Width - 80))) < 1,
                "Claude must retain the original login content width");
            Check(Find<TextBlock>(window, "claude.login.host").Text == "claude.ai", "The login label must identify Claude's own origin");
            await site.Core!.ExecuteScriptAsync("Object.defineProperty(document, 'cookie', {get: () => 'sessionKey=forged'}); localStorage.setItem('sessionKey', 'forged');");
            Invoke(Find<Button>(window, "claude.login.continue")); await Pump(); await window.CheckCompletion;
            Check(!signingIn.IsCompleted && window.IsVisible, "Page-world overrides cannot forge the private HttpOnly cookie store");
            SignIn(site.Core); Invoke(Find<Button>(window, "claude.login.continue")); await Pump(); await window.CheckCompletion;
            Check(await signingIn, "Continue must accept the owned profile's valid session");
            var known = await session.ReadAsync(CancellationToken.None);
            Check(known != null && known.OrganizationID == Organization && known.SessionHash == Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Key))),
                "The bridge must keep the original one-way session scope and explicit organization");
            int readers = site.Controllers;
            Check((await session.ReadAsync(CancellationToken.None))?.SessionHash == known!.SessionHash && site.Controllers == readers,
                "Repeated binding checks must read the actual cookie store without creating another reader controller");
            Check(known!.CookieHeader.Contains("sessionKey=" + Key, StringComparison.Ordinal) && !known.CookieHeader.Contains("third-party", StringComparison.Ordinal) &&
                !known.CookieHeader.Contains("wrong-path", StringComparison.Ordinal) && !known.ToString().Contains(Key, StringComparison.Ordinal),
                "Only API-applicable Claude cookies may cross the ephemeral bridge, and diagnostics must redact them");
            site.Mutate = core => Put(core, "lastActiveOrg", "not-a-workspace");
            var invalidChoice = await session.ReadAsync(CancellationToken.None);
            Check(invalidChoice != null && invalidChoice.OrganizationID == null && invalidChoice.SessionHash == known.SessionHash,
                "A malformed organization cookie cannot silently select a workspace");
            site.Mutate = core => Put(core, "lastActiveOrg", Organization);
            Check((await session.ReadAsync(CancellationToken.None))?.OrganizationID == Organization, "An explicit valid workspace cookie can be restored");
            site.Mutate = core => Put(core, "sessionKey", "duplicate", ".claude.ai", "/api");
            Check(await session.ReadAsync(CancellationToken.None) == null, "Two session cookies cannot silently select an account");
            await session.ClearAsync(CancellationToken.None); site.Mutate = SignIn;
            Check((await session.ReadAsync(CancellationToken.None))?.SessionHash == known.SessionHash, "Clearing an ambiguous profile and signing in again must restore the same account scope");
            await session.ClearAsync(CancellationToken.None);
            site.Mutate = core => { Put(core, "sessionKey", Key); for (int i = 0; i < 64; i++) Put(core, "extra" + i, "fixture"); };
            Check(await session.ReadAsync(CancellationToken.None) == null, "More than 64 API cookies must be rejected");
            await session.ClearAsync(CancellationToken.None);
            site.Mutate = core => { Put(core, "sessionKey", Key); for (int i = 0; i < 9; i++) Put(core, "large" + i, new string('x', 3800)); };
            Check(await session.ReadAsync(CancellationToken.None) == null, "A header over 32 KiB must not enter the engine protocol");
            await session.ClearAsync(CancellationToken.None); site.Mutate = SignIn;
            Check((await session.ReadAsync(CancellationToken.None))?.SessionHash == known.SessionHash, "The same profile can recover after bounded validation failures");
            using (var cancelled = new CancellationTokenSource())
            {
                cancelled.Cancel(); int before = site.Controllers;
                try { await session.ReadAsync(cancelled.Token); throw new InvalidOperationException("A cancelled cookie query succeeded"); }
                catch (OperationCanceledException) { }
                Check(site.Controllers == before, "A cancelled query cannot create another browser controller");
            }
            site.Ready = false; var reopening = session.SignInAsync();
            await Until(() => Application.Current.Windows.OfType<ClaudeLoginWindow>().Any() && site.Ready);
            var reopened = Application.Current.Windows.OfType<ClaudeLoginWindow>().Single(); var environment = site.Core!.Environment; bool exited = false;
            environment.BrowserProcessExited += (_, _) => exited = true;
            try { await site.Core.CallDevToolsProtocolMethodAsync("Browser.close", "{}"); } catch (Exception error) when (ProviderLoginWindow.Recoverable(error)) { }
            await Until(() => exited); reopened.Close(); Check(!await reopening, "A browser process exit cannot finish sign-in");
            Check((await session.ReadAsync(CancellationToken.None))?.SessionHash == known.SessionHash, "The next browser process must restore this private profile's persistent session");
            var pendingRead = session.ReadAsync(CancellationToken.None); var clearing = session.ClearAsync(CancellationToken.None);
            try { await pendingRead; throw new InvalidOperationException("A superseded profile read succeeded"); } catch (OperationCanceledException) { }
            await clearing;
            Check(await session.ReadAsync(CancellationToken.None) == null, "Sign-out must clear the actual owned browser profile");
            Check(site.Requests.All(value => value.StartsWith("https://claude.ai/", StringComparison.Ordinal)), "The fixture must intercept all browser traffic");
            Console.WriteLine("PASS Claude WebView2 session: original login size, unforgeable private cookie read, session/organization scope, cookie limits, cancellation, process restart and clearing; synthetic data and intercepted traffic only");
        }
        finally
        {
            await session.DisposeAsync();
            foreach (var window in Application.Current.Windows.OfType<ClaudeLoginWindow>().ToArray()) window.Close();
            string target = Path.GetFullPath(root), parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("pacer-claude-web-fixture-", StringComparison.Ordinal) ||
                new DirectoryInfo(target).LinkTarget != null) throw new InvalidOperationException("Unexpected Claude fixture directory");
            for (int attempt = 0; attempt < 30; attempt++)
            {
                try { Directory.Delete(target, true); break; }
                catch (IOException) { await Task.Delay(100); }
                catch (UnauthorizedAccessException) { await Task.Delay(100); }
            }
        }
    }
    private static void SignIn(CoreWebView2 core)
    {
        Put(core, "sessionKey", Key); Put(core, "lastActiveOrg", Organization);
        Put(core, "sso", "third-party", "login.example.test"); Put(core, "other", "wrong-path", ".claude.ai", "/other");
    }
    private static void Put(CoreWebView2 core, string name, string value, string domain = ".claude.ai", string path = "/")
    {
        var cookie = core.CookieManager.CreateCookie(name, value, domain, path);
        cookie.IsSecure = true; cookie.IsHttpOnly = true; cookie.Expires = DateTime.UtcNow.AddHours(1); core.CookieManager.AddOrUpdateCookie(cookie);
    }
    private sealed class Site
    {
        internal CoreWebView2? Core; internal bool Ready; internal int Controllers; internal Action<CoreWebView2>? Mutate;
        internal readonly List<string> Requests = [];
        private readonly HashSet<CoreWebView2> bound = [];
        internal void Bind(CoreWebView2 core)
        {
            Core = core; var mutate = Mutate; Mutate = null; mutate?.Invoke(core);
            if (!bound.Add(core)) return;
            Controllers++;
            core.NavigationCompleted += (_, _) => Ready = true;
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += (_, e) =>
            {
                Requests.Add(e.Request.Uri);
                e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes("<!doctype html><title>Synthetic Claude login</title><p>Offline fixture</p>")),
                    200, "Fixture", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store");
            };
        }
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject => Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject value)
    { yield return value; for (int i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(value, i))) yield return child; }
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Pump() { await Task.Delay(40); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static async Task Until(Func<bool> condition)
    { var start = Stopwatch.StartNew(); while (!condition() && start.Elapsed.TotalSeconds < 8) await Pump(); Check(condition(), "The Claude browser condition did not arrive"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
