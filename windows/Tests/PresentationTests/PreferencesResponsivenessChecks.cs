using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class PreferencesResponsivenessChecks
{
    internal static async Task Run()
    {
        foreach (string mode in new[] { "silent", "slow", "exit" })
        {
            await using var engine = new EngineClient(TimeSpan.FromMilliseconds(500));
            await engine.StartAsync(Environment.ProcessPath!, true, mode);
            int saves = 0, configurations = 0, beats = 0;
            var session = new PreferencesSession(new(), _ => { configurations++; return Task.CompletedTask; }, _ => { saves++; return true; },
                value => PreferencesAcknowledgement.ValidateAsync(engine, value, TimeSpan.FromMilliseconds(350)));
            var window = new SettingsWindow(UiText.For(false), session, new DemoStartupRegistration(), true, true, engine) { ShowActivated = false, IsHitTestVisible = false };
            var pulse = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) }; pulse.Tick += (_, _) => beats++;
            try
            {
                window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); pulse.Start();
                var choice = Find<ComboBox>(window, "settings.language"); var watch = Stopwatch.StartNew();
                choice.SelectedValue = "zh-Hans";
                Check(watch.Elapsed < TimeSpan.FromMilliseconds(125), "A settings edit returns to the UI dispatcher without waiting for the engine");
                await Until(() => choice.IsEnabled && Find<TextBlock>(window, "settings.issue").Text == UiText.For(false).Text("windows.settings.apply_failed"));
                Check(watch.Elapsed < TimeSpan.FromSeconds(3) && session.Current.Language == "system" && saves == 0 && configurations == 0,
                    "A silent, slow or exiting engine reports a bounded failure without configuring or saving the edit");
                if (mode != "exit")
                {
                    Check(beats >= 3, "Settings keep processing dispatcher callbacks during the acknowledgement timeout");
                    var count = await engine.QueryAsync<JsonElement>("inspectRequests", timeout: TimeSpan.FromMilliseconds(500));
                    Check(count.GetProperty("requests").GetInt32() == 1, "An unanswered edit is sent once without polling");
                }
                if (mode == "slow")
                {
                    await Task.Delay(1100);
                    Check(session.Current.Language == "system" && saves == 0, "A late acknowledgement cannot save a rejected edit");
                }
                bool responsive = false; await window.Dispatcher.InvokeAsync(() => responsive = true);
                Check(responsive && choice.IsEnabled, "Settings remain usable after timeout or engine exit");
                Console.WriteLine("PASS preference acknowledgement responsiveness: " + mode);
            }
            finally { pulse.Stop(); window.AllowClose = true; window.Close(); }
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var item in Descendants(child)) yield return item; } }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static async Task Until(Func<bool> condition)
    { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed < TimeSpan.FromSeconds(3)) await Task.Delay(20); Check(condition(), "The failed edit must restore its controls and visible error"); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
