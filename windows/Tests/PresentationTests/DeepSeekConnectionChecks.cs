using System;
using System.Collections.Generic;
using System.Diagnostics;
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
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class DeepSeekConnectionChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        await using var engine = new EngineClient(); bool reject = false; string? requestedPane = null;
        var ui = UiText.For(language == "zh-Hans");
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "deepseek",
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "enabled" } };
        var session = new PreferencesSession(preferences, async value => await engine.SendAsync("configure", value), _ => { if (reject) { reject = false; return false; } return true; });
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { IsHitTestVisible = false, ShowActivated = false };
        island.ProviderSettingsRequested += pane => requestedPane = pane;
        session.Changed += island.ApplyPreferences;
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        string name = language + (dark ? "-dark" : "-light"); const string key = "sk-synthetic-ui-key-0000000";
        try
        {
            island.ApplyPreferences(preferences); island.Show(); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
                configuration: preferences.EngineConfiguration(), referenceFixture: true);
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.Reading.Connected == true);
            await island.WaitForPresentationAsync();
            Check(engine.LatestSnapshot!.DeepseekConnection!.Mode == "account", "The demo starts with its original web wallet");
            await Source(window, "apiKey"); await Until(() => session.Current.DeepSeekBalanceSource == "apiKey" && engine.LatestSnapshot?.DeepseekConnection?.Mode == "apiKey");
            var field = Find<PasswordBox>(window, "settings.deepseek.key.input"); var save = Find<Button>(window, "settings.deepseek.key.save");
            Check(field.IsVisible && field.IsEnabled && !save.IsEnabled && engine.LatestSnapshot!.Wallet!.Balance == null,
                "API mode must show a real secure input and cannot retain the old web balance");
            Check(Find<TextBlock>(window, "settings.deepseek.local_state").Text == ui.Text("provider.state.found"),
                "Balance availability cannot replace the independent local-session status");
            Check(UIElementAutomationPeer.CreatePeerForElement(field)?.IsPassword() == true, "Assistive clients must see a password field");
            Button? oldConnect = null;
            foreach (string layout in new[] { "solo", "classic", "split" })
            {
                island.ApplyPreferences(session.Current with { ExpandedQuotaStyle = layout == "classic" ? "classic" : "split" });
                await engine.SendAsync("configure", new { providerModes = new { codex = layout == "solo" ? "disabled" : "enabled", claude = "disabled", deepseek = "enabled" } });
                island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
                var connect = Find<Button>(island, "deepseek.balance.connect");
                Check(connect.IsEnabled && (string)connect.Content == ui.Text("deepseek.paste_key_short"),
                    "The actual " + layout + " dial must offer the original API key action");
                requestedPane = null; Invoke(connect); await Until(() => requestedPane == "deepseek"); oldConnect = connect;
            }
            await engine.SendAsync("configure", session.Current.EngineConfiguration()); island.ApplyPreferences(session.Current); await Pump();
            window.CapturePreview(Path.Combine(output, "settings-deepseek-api-" + name + "-missing.png"));
            field.Password = "short"; Invoke(save); await Until(() => save.IsEnabled == false && field.IsEnabled && field.SecurePassword.Length == 0);
            Check(Find<TextBlock>(window, "settings.deepseek.key.issue").Text == ui.Text("deepseek.key_invalid"), "A rejected key must clear its field and show the original input issue");
            field.Password = new string('a', 257); Invoke(save);
            await Until(() => field.IsEnabled && field.SecurePassword.Length == 0);
            Check(engine.LatestSnapshot!.DeepseekConnection?.HasKey == false && Find<TextBlock>(window, "settings.deepseek.key.issue").Text == ui.Text("deepseek.key_invalid"),
                "An oversized key must be rejected without storing a truncated credential");
            field.Password = key; Invoke(save);
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.HasKey == true && engine.LatestSnapshot?.Wallet?.Balance == 86.4 && field.IsEnabled);
            Check(field.SecurePassword.Length == 0 && !save.IsEnabled, "The submitted secret must leave the view after success too");
            requestedPane = null; oldConnect!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Pump();
            Check(requestedPane == null, "A removed dial action cannot route after its connection context changes");
            Check(!JsonSerializer.Serialize(session.Current).Contains(key, StringComparison.Ordinal) && !JsonSerializer.Serialize(engine.LatestSnapshot).Contains(key, StringComparison.Ordinal),
                "Preferences and snapshots cannot retain a key");
            Check(!Descendants(window).OfType<TextBlock>().Any(value => value.Text.Contains(key, StringComparison.Ordinal)), "Visible or cached text cannot echo the key");
            var remove = Find<Button>(window, "settings.deepseek.key.remove"); Check(remove.IsVisible && remove.IsEnabled, "Only an existing app-owned key offers removal");
            window.CapturePreview(Path.Combine(output, "settings-deepseek-api-" + name + "-connected.png"));
            ulong before = engine.LatestSnapshot!.Sequence; Invoke(Find<Button>(window, "settings.deepseek.sign_in"));
            await Until(() => engine.LatestSnapshot!.Sequence > before && !engine.LatestSnapshot.DeepseekConnection!.Refreshing);
            var oldField = field; var oldSave = save;
            await window.NavigateAsync("appearance"); oldField.Password = key;
            oldSave.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Pump();
            Check(engine.LatestSnapshot.DeepseekConnection!.HasKey, "Removed controls cannot write a key or act on another pane");
            await window.NavigateAsync("deepseek"); await Pump();
            reject = true; await Source(window, "web");
            await Until(() => !reject && Find<Button>(window, "settings.deepseek.account_options").IsEnabled);
            Check(session.Current.DeepSeekBalanceSource == "apiKey" && engine.LatestSnapshot.DeepseekConnection!.Source == "apiKey",
                "A failed preference write must restore the actual billing source");
            await Until(() => engine.LatestSnapshot.Wallet!.Balance == 86.4);
            remove = Find<Button>(window, "settings.deepseek.key.remove"); Invoke(remove);
            await Until(() => engine.LatestSnapshot.DeepseekConnection!.HasKey == false && !remove.IsVisible);
            Check(engine.LatestSnapshot.Wallet!.Balance == null && session.Current.DeepSeekBalanceSource == "apiKey", "Removal must clear the balance while retaining the chosen source");
            field = Find<PasswordBox>(window, "settings.deepseek.key.input"); field.Password = key;
            Toggle(Find<CheckBox>(window, "settings.deepseek.enabled")); await Until(() => engine.LatestSnapshot.Modules!.Single(value => value.Provider == "deepseek").Enabled == false);
            Check(field.SecurePassword.Length == 0 && !field.IsVisible, "Disabling the module must clear an unfinished key");
            Console.WriteLine("PASS DeepSeek connection " + name + ": secure input, source menu, three dial routes, isolated demo credentials, refresh/removal, rollback and stale-control rejection");
        }
        finally { window.AllowClose = true; window.Close(); island.AllowClose = true; island.Close(); }
    }
    private static async Task Source(SettingsWindow window, string choice)
    {
        var button = Find<Button>(window, "settings.deepseek.account_options"); Invoke(button);
        await Until(() => button.ContextMenu?.IsOpen == true);
        var menu = button.ContextMenu!;
        Check(menu.Language == window.Language && menu.ActualWidth > 0, "The actual source menu must retain its UI language and layout");
        var item = menu.Items.OfType<MenuItem>().Single(value => (string?)value.Tag == choice);
        ((IInvokeProvider)new MenuItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
        await Pump();
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
        => Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { yield return root; for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) foreach (var value in Descendants(VisualTreeHelper.GetChild(root, index))) yield return value; }
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static async Task Pump() { await Task.Delay(30); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static async Task Until(Func<bool> condition)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed.TotalSeconds < 6) await Pump(); Check(condition(), "The DeepSeek connection did not settle in time"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
