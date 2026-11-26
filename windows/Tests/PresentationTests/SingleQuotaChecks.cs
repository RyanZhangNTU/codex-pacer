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
                var window = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false,
                    screenGeometry: PresentationWait.ReferenceScreen) { IsHitTestVisible = false };
                window.ApplyPreferences(new DesktopPreferences { IslandAppearance = "classic", ShowInFullscreen = true });
                try
                {
                    window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
                    await PresentationWait.RevealReferencePanelAsync(window, engine);
                    var slots = (Grid)window.FindName("QuotaSlots");
                    var (capsule, extra) = PresentationWait.ResetCapsule(window);
                    Check(capsule != null && slots.Children.Count == 3 && window.LogicalTarget.Height == 438 + extra,
                        $"Expected three quota cells and height 438 + {extra} with the reset capsule. Got {slots.Children.Count} cells, capsule={capsule != null}, target={window.LogicalTarget}");
                    // As on the Mac, the capsule sits in Codex's own column under its caption, centered on the ring.
                    var column = capsule!.Parent as QuotaCell;
                    double middle = column == null ? double.NaN : capsule.TransformToAncestor(column).TransformBounds(new Rect(capsule.RenderSize)) is var bounds
                        ? bounds.Left + bounds.Width / 2 : double.NaN;
                    Check(column != null && column.Children.OfType<QuotaDial>().First().AccessibleName.StartsWith("Codex", StringComparison.Ordinal) && Math.Abs(middle - column.ActualWidth / 2) <= 0.5,
                        "Shared with other services, the reset capsule is centered under Codex's own ring");
                    Check(System.Windows.Automation.AutomationProperties.GetName(capsule).Contains('·') && capsule.ToolTip == null,
                        "The reset capsule's name keeps the count and the deadline; a click, not a tooltip, leads to the deadlines");
                    var turns = Descendants(capsule).OfType<AlternatingQuotaText>().Single();
                    Check(turns.ShownTexts.Length == 2 && turns.ShownTexts.All(part => part.Length > 0 && !part.Contains('·')) && turns.Scheduling is { Scheduled: true } or { Clocks: > 0 },
                        "Shared with other services, the capsule takes turns between the count and the time in the collapsed bar's rotation");
                    // The panel redraws its quota with each reading, often sooner than a turn. A rebuilt
                    // capsule must pick up the turn in progress, or the time would never show.
                    for (int turn = 0; turn < 3 && turns.ShownText != turns.ShownTexts[1]; turn++)
                        await turns.WaitForNextCycleAsync(PresentationWait.Limit);
                    Check(turns.ShownText == turns.ShownTexts[1], "The shared capsule must reach the time left on its own");
                    var rebuilt = new AlternatingQuotaText { SharedPhase = true };
                    rebuilt.Update(turns.ShownTexts.Select(text => new AlternatingQuotaText.Item("codex", text, false)).ToArray(), true);
                    Check(rebuilt.ShownText == turns.ShownTexts[1], "A capsule rebuilt mid-rotation must keep the time left instead of starting over at the count");
                    foreach (string name in new[] { "claude", "codex" })
                    {
                        var modes = new Dictionary<string, string> { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled" };
                        modes[name] = "enabled";
                        await engine.SendAsync("configure", new { providerModes = modes });
                        await Until(() => slots.Children.Count == 1 && slots.Children[0] is SingleQuotaView single
                            && single.Dial.AccessibleName.StartsWith(name == "codex" ? "Codex" : "Claude", StringComparison.Ordinal), "The actual engine module choice must select the original single-provider layout");
                        await window.WaitForPresentationAsync();
                        // Codex alone carries its reset capsule at the right of the section's header row, not under the ring.
                        var (headerCapsule, _) = PresentationWait.ResetCapsule((StackPanel)window.FindName("QuotaHeaderTrailing"));
                        Check(name == "codex" ? headerCapsule != null : headerCapsule == null, "A lone Codex keeps its reset capsule in the header row, Claude has none");
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
                    Check(window.LogicalTarget.Height == PresentationWait.ReferenceHeight(window), "Changing provider count must not leave a stale single-provider content height");
                }
                finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
            }
        }
        finally { CultureInfo.CurrentUICulture = previous; }
        Console.WriteLine("PASS single quota: real engine module transitions, native component bounds, localized details and multi-provider height restore in both languages");
    }
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
