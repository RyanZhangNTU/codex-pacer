using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using CodexPacer.Windows;

internal static class SettingsPageUnitChecks
{
    internal static void Run()
    {
        Check(SettingsPagePolicy.InitialHelpProvider(["deepseek", "claude", "codex"]) == "codex", "Help follows the canonical service order, not snapshot order");
        Check(SettingsPagePolicy.InitialHelpProvider(["deepseek", "claude"]) == "claude"
            && SettingsPagePolicy.InitialHelpProvider(["deepseek"]) == "deepseek"
            && SettingsPagePolicy.InitialHelpProvider([]) == "codex", "Help starts at the first enabled service with a deterministic empty fallback");
        Check(!SettingsPagePolicy.ShowExpandedQuotaStyle(["deepseek", "deepseek"])
            && SettingsPagePolicy.ShowExpandedQuotaStyle(["codex", "deepseek"])
            && SettingsPagePolicy.ShowExpandedQuotaStyle([]), "The expanded quota-style row is hidden only for DeepSeek alone");
        var opened = new List<Uri>();
        Check(SettingsPagePolicy.OpenTransparency(uri => { opened.Add(uri); return true; })
            && opened.Count == 1 && opened[0].AbsoluteUri == "ms-settings:easeofaccess-visualeffects", "The transparency action opens only its fixed Windows Settings page");
        Check(!SettingsPagePolicy.OpenTransparency(_ => false)
            && !SettingsPagePolicy.OpenTransparency(_ => throw new Win32Exception(5)), "Settings launch rejection and failure are reported without retrying");
        foreach (string language in new[] { "en", "zh-Hans" })
        {
            var uri = SettingsPagePolicy.PricingDocumentation(language);
            Check(uri.Scheme == "https" && uri.Host == "api-docs.deepseek.com" && uri.Port == 443
                && uri.AbsolutePath == (language == "en" ? "/quick_start/pricing" : "/zh-cn/quick_start/pricing"), "Pricing documentation follows the app language");
            Check(SettingsPagePolicy.OpenPricing(language, target => { opened.Add(target); return true; }) && opened[^1] == uri, "The production pricing action uses the localized target");
        }
        Check(!SettingsPagePolicy.OpenPricing("en", _ => throw new InvalidOperationException()), "A failed browser launch is reported");

        var catalog = Catalog("https://github.com/RyanZhangNTU/codex-pacer");
        var backend = new ShareBackend(); int created = 0;
        using var share = new SupportShareSession(() => { created++; return backend; });
        Check(!share.Show(IntPtr.Zero, catalog, UiText.For(false)) && created == 0, "Sharing requires a live owner before creating a system object");
        foreach (string invalid in new[] { "", "http://github.com/RyanZhangNTU/codex-pacer", "https://github.com/other/private", "https://github.com/RyanZhangNTU/codex-pacer?task=private", "https://github.com/RyanZhangNTU/codex-pacer#private", "https://user@github.com/RyanZhangNTU/codex-pacer" })
            Check(!share.Show(new(7), Catalog(invalid), UiText.For(false)) && created == 0, "Untrusted or content-bearing links never reach the share backend");
        foreach (bool chinese in new[] { false, true })
        {
            var ui = UiText.For(chinese);
            Check(share.Show(new(7), catalog, ui) && backend.Last is { } payload
                && payload.Link.AbsoluteUri == catalog.Links["repository"]
                && payload.Title == ui.Text("support.share.subject") && payload.Message == ui.Text("windows.support.share_message")
                && !payload.Message.Contains("Mac", StringComparison.Ordinal), "Sharing contains only the public link and localized Windows product text");
        }
        Check(created == 1 && backend.Calls == 2, "Repeated explicit shares reuse one owner-bound backend");
        backend.Fail = true;
        Check(!share.Show(new(7), catalog, UiText.For(false)), "System sharing failure leaves Copy Link available");
        share.Dispose(); share.Dispose();
        Check(backend.Disposals == 1 && !share.Show(new(7), catalog, UiText.For(false)) && backend.Calls == 3, "Closing the page detaches sharing once and rejects later actions");
        Console.WriteLine("PASS settings page units: Help defaults, DeepSeek-only rows, localized links, Windows Settings and private share boundaries");
    }
    private static GuideCatalog Catalog(string link) => new(1, null, 4, "4.0", false, true, "4.0", [],
        new Dictionary<string, string>(), [], [], new Dictionary<string, string> { ["repository"] = link }, null);
    private sealed class ShareBackend : ISupportShareBackend
    {
        internal int Calls, Disposals;
        internal bool Fail;
        internal SupportSharePayload? Last;
        public bool Show(IntPtr owner, SupportSharePayload payload) { Calls++; if (Fail) throw new COMException(); Last = payload; return true; }
        public void Dispose() => Disposals++;
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
