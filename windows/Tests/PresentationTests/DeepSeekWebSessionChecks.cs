using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
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
using Microsoft.Web.WebView2.Wpf;

internal static class DeepSeekWebSessionChecks
{
    internal static async Task Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-web-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var fixture = new Site();
        var session = new DeepSeekWebSession(UiText.For(false), Path.Combine(root, "first"), fixture.Install, false);
        try
        {
            Check(session.Available, "The real WebView2 runtime is required for the browser integration checks");
            var absent = await session.ReadAsync(CancellationToken.None);
            Check(absent.State == "signedOut" && fixture.Reads == 0, "A fresh private profile cannot issue an authenticated summary request");
            var login = session.SignInAsync();
            await Until(() => Application.Current.Windows.OfType<DeepSeekLoginWindow>().Any() && fixture.Main != null && fixture.Ready);
            var window = Application.Current.Windows.OfType<DeepSeekLoginWindow>().Single();
            Check(Math.Abs(window.ClientContent.ActualWidth - Math.Min(760, Math.Max(420, SystemParameters.WorkArea.Width - 80))) < 1,
                "The login body must retain the original 760-point initial width");
            Check(Find<TextBlock>(window, "deepseek.login.host").Text == "platform.deepseek.com", "Only the current host belongs in the address label");
            Invoke(Find<Button>(window, "deepseek.login.continue")); await Pump(); await window.CheckCompletion;
            Check(!login.IsCompleted && window.IsVisible, "An untrusted main-world storage override cannot satisfy the isolated sign-in check");
            await fixture.Main!.ExecuteScriptAsync("document.getElementById('popup').click()");
            await Until(() => Application.Current.Windows.OfType<Window>().Count(value => value != window) > 0);
            var popup = Application.Current.Windows.OfType<Window>().Single(value => value != window);
            popup.Close(); await Pump();
            await fixture.Main.ExecuteScriptAsync("document.getElementById('signin').click()");
            Invoke(Find<Button>(window, "deepseek.login.continue")); await Pump(); await window.CheckCompletion;
            Check(await login, "A real stored synthetic token must complete the original Continue action");
            var known = await session.ReadAsync(CancellationToken.None);
            Check(known is { State: "ok", AlertEnabled: true, AlertBound: "20", Estimation: "21600000" } &&
                known.Normal!.Single() == "80" && known.Bonus!.Single() == "6.4", "The original script must reduce the actual simulated summary response");
            Check(!JsonSerializer.Serialize(known).Contains(Site.Key, StringComparison.Ordinal) &&
                !JsonSerializer.Serialize(known).Contains("unrelated-account", StringComparison.Ordinal), "The browser result cannot contain storage credentials or account identity");
            var previous = fixture.Main; fixture.Ready = false;
            var reopen = session.SignInAsync();
            await Until(() => Application.Current.Windows.OfType<DeepSeekLoginWindow>().Any() && fixture.Ready && !ReferenceEquals(fixture.Main, previous));
            var current = Application.Current.Windows.OfType<DeepSeekLoginWindow>().Single();
            var runtime = fixture.Main!.Environment; bool exited = false;
            runtime.BrowserProcessExited += (_, _) => exited = true;
            try { await fixture.Main.CallDevToolsProtocolMethodAsync("Browser.close", "{}"); } catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error)) { }
            await Until(() => exited); current.Close(); Check(!await reopen, "A closed browser process cannot complete a sign-in");
            Check((await session.ReadAsync(CancellationToken.None)).Normal?.Single() == "80", "A new browser process must restore the same private profile");
            fixture.Status = 401; Check((await session.ReadAsync(CancellationToken.None)).State == "signedOut", "401 must preserve the original signed-out result");
            fixture.Status = 200; fixture.Challenge = true;
            Check((await session.ReadAsync(CancellationToken.None)).State == "challenge", "The original WAF result must ask for a visible sign-in");
            fixture.Challenge = false;
            await using (var separate = new DeepSeekWebSession(UiText.For(false), Path.Combine(root, "separate"), fixture.Install, false))
                Check((await separate.ReadAsync(CancellationToken.None)).State == "signedOut", "Another private profile cannot inherit this sign-in");
            fixture.Hold = true;
            using (var cancel = new CancellationTokenSource())
            {
                var read = session.ReadAsync(cancel.Token); await Until(() => fixture.Deferred != null); cancel.Cancel();
                try { await read; throw new InvalidOperationException("The reader ignored cancellation"); }
                catch (OperationCanceledException) { }
                fixture.Release(); fixture.Hold = false;
            }
            await session.ClearAsync(CancellationToken.None);
            Check((await session.ReadAsync(CancellationToken.None)).State == "signedOut", "Sign-out must clear the actual private browser storage");
            Check(fixture.Outside == 0, "Unexpected fixture requests were blocked: " + string.Join(", ", fixture.Blocked));
            Console.WriteLine("PASS WebView2 session: private profiles, isolated native scripts, original login/popups, process restart, bounded replies, cancellation and clearing; intercepted page traffic only");
        }
        finally
        {
            fixture.Release(); await session.DisposeAsync();
            foreach (var window in Application.Current.Windows.OfType<DeepSeekLoginWindow>().ToArray()) window.Close();
            // Only the unique fixture root is eligible for cleanup. WebView2 may
            // briefly retain its profile after the last controller is disposed.
            string target = Path.GetFullPath(root), parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("pacer-web-fixture-", StringComparison.Ordinal) ||
                new DirectoryInfo(target).LinkTarget != null) throw new InvalidOperationException("Unexpected browser fixture directory");
            for (int attempt = 0; attempt < 20; attempt++)
            {
                try { Directory.Delete(target, true); break; }
                catch (IOException) { await Task.Delay(100); }
                catch (UnauthorizedAccessException) { await Task.Delay(100); }
            }
        }
    }
    internal sealed class Site
    {
        internal const string Key = "synthetic-web-token-000000000000";
        internal CoreWebView2? Main;
        internal bool Ready, Challenge, Hold;
        internal int Reads, Outside, Status = 200;
        internal string NormalBalance = "80.00";
        internal readonly List<string> Blocked = new();
        internal CoreWebView2Deferral? Deferred;
        private CoreWebView2WebResourceRequestedEventArgs? pending;
        private CoreWebView2? pendingCore;
        internal void Install(CoreWebView2 core)
        {
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.NavigationCompleted += (_, e) => { if (e.IsSuccess && core.Source == "https://platform.deepseek.com/usage") Ready = true; };
            core.WebResourceRequested += (_, e) =>
            {
                string url = e.Request.Uri;
                if (url == "https://platform.deepseek.com/usage")
                {
                    Main = core; Ready = false;
                    Respond(core, e, 200, "<!doctype html><title>Fixture</title><button id='signin' onclick=\"localStorage.setItem('userToken', JSON.stringify({value:'" + Key +
                        "'}));localStorage.setItem('__appKit_userInfo', JSON.stringify({balanceAlert:{CNY:{enabled:true,alertBound:20}}}))\">Synthetic sign in</button>" +
                        "<button id='popup' onclick=\"window.open('https://auth.example.invalid/login')\">Popup</button><script>localStorage.getItem=()=>JSON.stringify({value:'untrusted-world-token'});</script>", "Content-Type: text/html");
                }
                else if (url == "https://auth.example.invalid/login") Respond(core, e, 200, "<!doctype html><title>Popup</title>", "Content-Type: text/html");
                else if (url is "https://platform.deepseek.com/favicon.ico" or "https://auth.example.invalid/favicon.ico")
                    Respond(core, e, 204, "", "Cache-Control: no-store");
                else if (url == "https://platform.deepseek.com/api/v0/users/get_user_summary")
                {
                    Reads++;
                    if (Hold) { pending = e; pendingCore = core; Deferred = e.GetDeferral(); return; }
                    Summary(core, e);
                }
                else if (url.StartsWith("https://platform.deepseek.com/.codex-pacer/balance/", StringComparison.Ordinal))
                    Respond(core, e, 403, "", "Cache-Control: no-store"); // The reader replaces this with its own blank document.
                else { Outside++; if (Blocked.Count < 8) Blocked.Add(new Uri(url).GetLeftPart(UriPartial.Path)); Respond(core, e, 403, "", "Cache-Control: no-store"); }
            };
        }
        private void Summary(CoreWebView2 core, CoreWebView2WebResourceRequestedEventArgs e)
        {
            if (Status == 503) { Respond(core, e, 503, "<!doctype html><title>Temporarily unavailable</title>", "Content-Type: text/html"); return; }
            Respond(core, e, Status, JsonSerializer.Serialize(new { code = 0, data = new { biz_data = new {
                normal_wallets = new[] { new { currency = "CNY", balance = NormalBalance } },
                bonus_wallets = new[] { new { currency = "CNY", balance = "6.40" } }, total_available_token_estimation = 21600000, account = "unrelated-account"
            } } }),
                "Content-Type: application/json" + (Challenge ? "\r\nx-amzn-waf-action: challenge" : ""));
        }
        internal void Release()
        {
            if (Deferred == null) return;
            var deferred = Deferred; var request = pending; var core = pendingCore;
            Deferred = null; pending = null; pendingCore = null;
            try { if (request != null && core != null) Summary(core, request); } catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error)) { }
            try { deferred.Dispose(); } catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error)) { }
        }
        private static void Respond(CoreWebView2 core, CoreWebView2WebResourceRequestedEventArgs e, int status, string body, string headers) =>
            e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(body)), status, "Fixture", headers);
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject =>
        Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject value)
    { yield return value; for (int i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(value, i))) yield return child; }
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Pump() { await Task.Delay(40); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static async Task Until(Func<bool> condition)
    { var start = Stopwatch.StartNew(); while (!condition() && start.Elapsed.TotalSeconds < 8) await Pump(); Check(condition(), "The browser condition did not arrive"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
