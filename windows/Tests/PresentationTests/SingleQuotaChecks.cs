using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class SingleQuotaChecks
{
    internal static async Task Run(string output)
    {
        CultureInfo previous = CultureInfo.CurrentUICulture;
        try
        {
            foreach (string language in new[] { "en", "zh-Hans" })
            {
                CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
                await using var engine = new EngineClient(); EngineSnapshot? latest = null;
                engine.Snapshot += value => latest = value;
                var window = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { IsHitTestVisible = false };
                try
                {
                    window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
                    window.Reveal(); await window.WaitForPresentationAsync();
                    var slots = (Grid)window.FindName("QuotaSlots");
                    Check(slots.Children.Count == 3 && window.LogicalTarget.Height == 440, "The existing multi-provider reference layout must retain its original height");
                    foreach (string name in new[] { "claude", "codex" })
                    {
                        var modes = new Dictionary<string, string> { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled" };
                        modes[name] = "enabled";
                        await engine.SendAsync("configure", new { providerModes = modes });
                        await Until(() => slots.Children.Count == 1 && slots.Children[0] is SingleQuotaView single
                            && single.Dial.AccessibleName.StartsWith(name == "codex" ? "Codex" : "Claude", StringComparison.Ordinal), "The actual engine module choice must select the original single-provider layout");
                        await window.WaitForPresentationAsync();
                        var view = (SingleQuotaView)slots.Children[0];
                        var projected = latest!.QuotaDashboard!.Providers.Single();
                        Check(view.Dial.ActualWidth == 104 && view.Dial.ActualHeight == 104 && view.ActualHeight == 110
                            && view.Margin == new Thickness(9, 0, 9, 0), "A single service must retain the original ring size, row inset and status gap");
                        Check(view.Dial.Split == (name == "claude"), "The real weekly-only Codex fixture must keep one gauge while Claude retains both arcs");
                        var texts = Descendants(view).OfType<TextBlock>().Select(value => value.Text).ToArray();
                        Check(texts.Contains(projected.Weekly.PaceText) && (projected.Weekly.ResetMoment == null
                            || texts.Contains(name == "claude" ? projected.Weekly.ResetAtText : projected.Weekly.ResetMoment)),
                            "Single-provider details must display the common engine's localized live pace and reset, without recalculating them in C#");
                        Check(UIElementAutomationPeer.CreatePeerForElement(view.Dial).GetName().Contains(projected.Weekly.AccessibilityLabel),
                            "The same provider and weekly reading must be exposed to accessibility");
                        window.CapturePreview(Path.Combine(output, "single-" + language + "-" + name + ".png"));
                    }
                    await engine.SendAsync("configure", new { providerModes = new { codex = "enabled", claude = "enabled", deepseek = "enabled" } });
                    await Until(() => slots.Children.Count == 3, "Restoring all modules must return to the original multi-provider rings");
                    await window.WaitForPresentationAsync();
                    Check(window.LogicalTarget.Height == 440, "Changing provider count must not leave a stale single-provider content height");
                }
                finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
            }
        }
        finally { CultureInfo.CurrentUICulture = previous; }
        Console.WriteLine("PASS single quota: real engine module transitions, native component bounds, localized details and multi-provider height restore in both languages");
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
