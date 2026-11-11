using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class ClassicLayoutChecks
{
    internal static async Task Run(string language, string output, bool animations = false)
    {
        await using var engine = new EngineClient();
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: animations) { IsHitTestVisible = false, ShowActivated = false };
        int configurations = 0; bool rejectSave = false;
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "expandedPanel" };
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => { if (rejectSave) { rejectSave = false; return false; } return true; });
        session.Changed += island.ApplyPreferences;
        var settings = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, true, engine) { IsHitTestVisible = false, ShowActivated = false };
        try
        {
            island.Show(); settings.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            ulong sequence = engine.LatestSnapshot!.Sequence;
            // The style is a choice of the quota blocks on the Expanded Panel page.
            await Until(() => Descendants(settings).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "panel.block.codex"));
            settings.SelectPanelBlock("codex"); await Pump();
            var classic = Find<RadioButton>(settings, "panel.option.codex.style.classic"); Select(classic);
            await Until(() => session.Current.ExpandedQuotaStyle == "classic" && Descendants(island).OfType<ClassicQuotaView>().Any());
            await island.WaitForPresentationAsync();
            Check(configurations == 0 && engine.LatestSnapshot!.Sequence == sequence, "A presentation style change cannot restart collectors or request a new engine snapshot");
            Check(Descendants(island).OfType<QuotaDial>().Count() == 3 && Descendants(island).OfType<QuotaDial>().All(value => value.ActualWidth == 88),
                "The actual three-provider classic row must use three original 88-point dials");
            island.CapturePreview(Path.Combine(output, "classic-layout-" + language + (animations ? "-motion" : "-reduced") + "-all.png"));
            rejectSave = true; Select(Find<RadioButton>(settings, "panel.option.codex.style.split"));
            await Until(() => classic.IsChecked == true && classic.IsEnabled);
            Check(session.Current.ExpandedQuotaStyle == "classic" && Descendants(island).OfType<ClassicQuotaView>().Any() && configurations == 0,
                "A rejected style write must keep the actual island at its previous acknowledged style");
            var combinations = new[] { new[] { "codex" }, new[] { "claude" }, new[] { "codex", "claude" }, new[] { "codex", "deepseek" }, new[] { "claude", "deepseek" }, Array.Empty<string>(), new[] { "codex", "claude", "deepseek" } };
            foreach (var providers in combinations)
            {
                await PresentationWait.CommandSnapshotAsync(engine, "configure", new { enabledProviders = providers }); await island.WaitForPresentationAsync();
                var data = engine.LatestSnapshot!.QuotaDashboard!;
                if (providers.Length == 0)
                    Check(!Descendants(island).OfType<ClassicQuotaView>().Any() && !Descendants(island).OfType<QuotaDial>().Any()
                        && Descendants(island).OfType<Grid>().Any(value => AutomationProperties.GetAutomationId(value) == "island.none"),
                        "Without a service the panel keeps its task list and offers Settings, as on the Mac");
                else if (data.Classic.Kind == "legacyCodex")
                    Check(Descendants(island).OfType<LegacyQuotaView>().Any() && !Descendants(island).OfType<ClassicQuotaView>().Any(),
                        "Codex alone with its weekly-only account must keep the original classic bar exception");
                else
                {
                    var view = Descendants(island).OfType<ClassicQuotaView>().Single();
                    var cells = Descendants(view).OfType<FrameworkElement>().Where(value => AutomationProperties.GetAutomationId(value).StartsWith("quota.classic.", StringComparison.Ordinal)).ToArray();
                    Check(cells.Select(AutomationProperties.GetAutomationId).SequenceEqual(data.Classic.Slots.Select(slot => "quota.classic." + slot.Id)),
                        "Classic cells must follow the shared provider/period order for every enabled combination");
                    Check(Descendants(view).OfType<QuotaDial>().All(value => value.ActualWidth == 88 && value.ActualHeight == 88), "Every classic slot must keep its native size");
                    if (providers.SequenceEqual(new[] { "claude" }))
                    {
                        Check(data.Classic.Slots.Select(slot => slot.Period).SequenceEqual(new[] { "5h", "7d" }) && Descendants(view).OfType<QuotaDial>().Count() == 2,
                            "A single dual-window service must show both original period rings");
                        Check(Descendants(view).OfType<StackPanel>().Any(value => AutomationProperties.GetAutomationId(value) == "quota.details.classic"),
                            "Classic shows side details alongside both original rings when the section has one service");
                    }
                }
            }
            settings.SelectPanelBlock("codex"); await Pump();
            Select(Find<RadioButton>(settings, "panel.option.codex.style.split"));
            await Until(() => session.Current.ExpandedQuotaStyle == "split" && !Descendants(island).OfType<ClassicQuotaView>().Any());
            await island.WaitForPresentationAsync();
            Check(Descendants(island).OfType<QuotaDial>().All(value => value.ActualWidth == 104), "Returning to Split Ring must restore the original multi-provider sizes");
            Console.WriteLine("PASS classic layout " + language + (animations ? "-motion" : "-reduced") + ": real settings selection, save rollback, unchanged engine sequence, seven provider combinations and original period sizes");
        }
        finally { settings.AllowClose = true; settings.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); }
    }
    private static void Select(RadioButton radio) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(radio).GetPattern(PatternInterface.SelectionItem)).Select();
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed.TotalSeconds < PresentationWait.Limit.TotalSeconds) await Task.Delay(20); Check(condition(), "The bounded classic layout action must finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
