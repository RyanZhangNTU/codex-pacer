using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
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

internal static class PersistentSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output, string app)
    {
        var previous = CultureInfo.CurrentUICulture; CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        string scenario = language + (dark ? "-dark" : "-light");
        string root = Path.Combine(Path.GetTempPath(), "pacer-preferences-中文 space-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        string file = Path.Combine(root, "preferences.json"), capture = Path.Combine(output, "persisted-restart-" + scenario + ".png");
        // Keep the original failed-write/rollback assertions through maintenance's protected mode.
        var store = new PreferencesStore(file, recoverDamagedFiles: false); _ = store.Load();
        var initial = new DesktopPreferences { IslandAppearance = "classic" };
        Check(store.Save(initial), "An isolated synthetic profile initializes");
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
            configuration: initial.EngineConfiguration(), referenceFixture: true);
        var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), store.Save,
            value => PreferencesAcknowledgement.ValidateAsync(engine, value));
        var ui = UiText.For(language == "zh-Hans");
        var first = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark, engine) { ShowActivated = false, IsHitTestVisible = false };
        SettingsWindow? second = null;
        try
        {
            first.Show(); await Pump();
            Toggle(Find<CheckBox>(first, "settings.hide_projects"));
            await Until(() => session.Current.HideProjects && Find<CheckBox>(first, "settings.hide_projects").IsEnabled);
            second = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark, engine) { ShowActivated = false, IsHitTestVisible = false };
            second.Show(); await Pump(); Toggle(Find<CheckBox>(second, "settings.app_buttons"));
            await Until(() => !session.Current.ShowAppButtons && Find<CheckBox>(second, "settings.app_buttons").IsEnabled);
            Check(Find<CheckBox>(first, "settings.app_buttons").IsChecked == false && session.Current.HideProjects,
                "Two settings windows share acknowledged edits without losing privacy");
            var languagePicker = Find<ComboBox>(first, "settings.language");
            languagePicker.SelectedValue = language;
            await Until(() => session.Current.Language == language && languagePicker.IsEnabled);
            await first.NavigateAsync("appearance"); await Pump();
            Select(Find<RadioButton>(first, "appearance.quota.classic"));
            await Until(() => session.Current.ExpandedQuotaStyle == "classic" && Find<RadioButton>(first, "appearance.quota.classic").IsEnabled);
            Select(Find<RadioButton>(first, "appearance.mode.notch"));
            await Until(() => session.Current.DisplayMode == "notch" && Find<RadioButton>(first, "appearance.mode.notch").IsEnabled);
            Select(Find<RadioButton>(first, "appearance.mode.custom"));
            await Until(() => session.Current.DisplayMode == "floating" && Find<RadioButton>(first, "appearance.position.bottomRight").IsEnabled);
            Select(Find<RadioButton>(first, "appearance.position.bottomRight"));
            await Until(() => session.Current.Position == "bottomRight" && Find<RadioButton>(first, "appearance.position.bottomRight").IsEnabled);
            await first.NavigateAsync("general"); await Pump();
            byte[] saved = File.ReadAllBytes(file);
            const string damaged = "{synthetic damaged preferences";
            File.WriteAllText(file, damaged); Toggle(Find<CheckBox>(first, "settings.hide_projects"));
            await Until(() => Find<CheckBox>(first, "settings.hide_projects").IsEnabled);
            Check(session.Current.HideProjects && Find<CheckBox>(first, "settings.hide_projects").IsChecked == true
                && Find<TextBlock>(first, "settings.issue").Text == ui.Text("windows.settings.save_failed"),
                "A real disk conflict rolls back engine and fields and shows its save error");
            Check(File.ReadAllText(file) == damaged && engine.LatestSnapshot!.Tasks.All(task => task.Title == ui.Text("activity.local_task")),
                "A rejected write preserves damaged bytes and restores privacy before returning");
            File.WriteAllBytes(file, saved);
            first.CapturePreview(Path.Combine(output, "persisted-before-" + scenario + ".png"));
            first.AllowClose = true; first.Close(); second.AllowClose = true; second.Close();
            await engine.DisposeAsync();
            var start = new ProcessStartInfo(app) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(app)! };
            foreach (string argument in new[] { "--demo", "--reference-fixture", "--demo-preferences", file, "--theme", dark ? "dark" : "light", "--settings-preview", "--capture-preview", capture }) start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new IOException("The isolated demo could not restart.");
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)); }
            finally { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            Check(process.ExitCode == 0 && File.Exists(capture), "The actual application restarts with its isolated profile and closes itself");
            using var metadata = JsonDocument.Parse(File.ReadAllBytes(Path.ChangeExtension(capture, ".json")));
            var actual = metadata.RootElement;
            Check(actual.GetProperty("language").GetString() == language && actual.GetProperty("dark").GetBoolean() == dark
                && actual.GetProperty("pane").GetString() == "general" && actual.GetProperty("expandedQuotaStyle").GetString() == "classic",
                "The actual restarted app restores language, theme fixture, pane and quota style");
            Check(actual.GetProperty("hideProjects").GetBoolean() && !actual.GetProperty("showAppButtons").GetBoolean()
                && actual.GetProperty("languageChoice").GetString() == language && actual.GetProperty("renderMode").GetString() == "SoftwareOnly",
                "Restored controls reflect the saved privacy, app-button and language choices");
            var restored = new PreferencesStore(file).Load();
            Check(!restored.Unavailable && restored.Value.Position == "bottomRight" && restored.Value.HasChosenPosition && restored.Value.DisplayMode == "floating",
                "Explicit positions survive a complete process restart");
            Console.WriteLine("PASS persistent settings " + scenario + ": real acknowledgement, two windows, disk rollback, application restart and synthetic capture");
        }
        finally
        {
            await engine.DisposeAsync();
            first.AllowClose = true; if (first.IsLoaded) first.Close();
            if (second != null) { second.AllowClose = true; if (second.IsLoaded) second.Close(); }
            foreach (string entry in Directory.EnumerateFiles(root)) File.Delete(entry);
            Directory.Delete(root); CultureInfo.CurrentUICulture = previous;
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var item in Descendants(child)) yield return item; } }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Toggle(CheckBox check) => ((IToggleProvider)new CheckBoxAutomationPeer(check).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Select(RadioButton value) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(value).GetPattern(PatternInterface.SelectionItem)).Select();
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(25); Check(condition(), "The acknowledged UI edit must settle"); await Pump(); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
