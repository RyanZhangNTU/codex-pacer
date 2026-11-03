using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class DisplaySettingsChecks
{
    internal static async Task Run(string language, bool dark)
    {
        var main = new DisplayMonitor(new(1), "qa-main", "QA Main", "DISPLAY1", new(0, 0, 2560, 1440), new(0, 0, 2560, 1400), true);
        var left = new DisplayMonitor(new(2), "qa-left", "QA Left", "DISPLAY2", new(-1920, 0, 0, 1080), new(-1920, 0, 0, 1040), false);
        using var topology = new MutableDisplayTopology(main, left);
        int configurations = 0; bool reject = false;
        var session = new PreferencesSession(new() { LastSettingsPane = "appearance" }, _ => { configurations++; return Task.CompletedTask; }, _ =>
        { if (!reject) return true; reject = false; return false; });
        var ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, displayTopology: topology) { IsHitTestVisible = false, ShowActivated = false };
        try
        {
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var picker = Find<ComboBox>(window, "appearance.display"); var fullscreen = Find<CheckBox>(window, "appearance.fullscreen");
            Check(picker.IsEnabled && fullscreen.IsEnabled && picker.Items.Count == 4, "Automatic, Main Display, both monitors and fullscreen are accessible choices");
            Check(AutomationProperties.GetName(picker) == ui.Text("settings.display_picker") && AutomationProperties.GetName(fullscreen) == ui.Text("windows.appearance.fullscreen"),
                "Display and fullscreen keep localized accessible names");
            Check(picker.SelectedIndex == 0 && !fullscreen.IsChecked.GetValueOrDefault(), "The UI retains the Mac defaults");
            picker.SelectedIndex = 3;
            await Until(() => session.Current.DisplayID == left.DevicePath && picker.IsEnabled);
            Check(session.Current.DisplaySelection == "specified" && session.Current.DisplayX == -1920 && session.Current.DisplayName == left.Name, "Selection stores stable identity and fallback position");
            ((IToggleProvider)new CheckBoxAutomationPeer(fullscreen).GetPattern(PatternInterface.Toggle)).Toggle();
            await Until(() => session.Current.ShowInFullscreen && fullscreen.IsEnabled);
            reject = true; picker.SelectedIndex = 1;
            await Until(() => !reject && picker.IsEnabled && picker.SelectedIndex == 3);
            Check(session.Current.DisplayID == left.DevicePath && fullscreen.IsChecked == true, "Failed saves restore the acknowledged display and leave fullscreen unchanged");
            string before = JsonSerializer.Serialize(session.Current);
            topology.Set(main); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(JsonSerializer.Serialize(session.Current) == before && picker.SelectedItem is ComboBoxItem { IsEnabled: false }, "Disconnect retains the selection and shows a disabled saved item");
            Check(Find<TextBlock>(window, "appearance.display.status").Text == ui.Text("windows.appearance.display_fallback"), "The fallback explanation is localized");
            topology.Set(main, left with { DeviceName = "DISPLAY8" }); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(picker.SelectedItem is ComboBoxItem { IsEnabled: true } && picker.SelectedIndex == 3
                && Find<TextBlock>(window, "appearance.display.status").Visibility == Visibility.Collapsed, "Reconnect restores the saved choice without writing preferences");
            picker.SelectedIndex = 1; await Until(() => session.Current.DisplaySelection == "primary" && picker.IsEnabled);
            picker.SelectedIndex = 0; await Until(() => session.Current.DisplaySelection == "automatic" && picker.IsEnabled);
            Check(configurations == 0, "Selection, fullscreen, disconnect and reconnect never reconfigure collectors");
            window.AllowClose = true; window.Close();
            var reopened = new SettingsWindow(ui, session, new Startup(), true, dark, displayTopology: topology) { IsHitTestVisible = false, ShowActivated = false };
            try
            {
                reopened.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                Check(Find<ComboBox>(reopened, "appearance.display").SelectedIndex == 0 && Find<CheckBox>(reopened, "appearance.fullscreen").IsChecked == true,
                    "Reopening restores both independent choices");
            }
            finally { reopened.AllowClose = true; reopened.Close(); }
            Console.WriteLine("PASS display settings " + language + (dark ? "-dark" : "-light") + ": identity, defaults, rollback, disconnect/reconnect and collector isolation");
        }
        finally { window.AllowClose = true; window.Close(); }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { yield return root; for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var item in Descendants(VisualTreeHelper.GetChild(root, i))) yield return item; }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static async Task Until(Func<bool> ready)
    { var clock = Stopwatch.StartNew(); while (!ready() && clock.Elapsed.TotalSeconds < 5) await Task.Delay(20); Check(ready(), "Display settings did not settle"); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool value) => true; }
}
