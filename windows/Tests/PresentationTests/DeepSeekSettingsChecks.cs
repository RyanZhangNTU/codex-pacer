using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class DeepSeekSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        CultureInfo previous = CultureInfo.CurrentUICulture; CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        await using var engine = new EngineClient(); bool reject = false; int configurations = 0;
        var preferences = new DesktopPreferences { LastSettingsPane = "deepseek", ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "enabled" } };
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => { if (reject) { reject = false; return false; } return true; });
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { IsHitTestVisible = false, ShowActivated = false };
        session.Changed += island.ApplyPreferences;
        var window = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        string scenario = language + (dark ? "-dark" : "-light");
        try
        {
            window.Show(); island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, configuration: preferences.EngineConfiguration(), referenceFixture: true);
            island.Reveal(); await island.WaitForPresentationAsync(); await Pump();
            var module = Find<CheckBox>(window, "settings.deepseek.enabled"); var daily = Find<TextBox>(window, "settings.deepseek.budget.daily"); var weekly = Find<TextBox>(window, "settings.deepseek.budget.weekly");
            var budget = Find<RadioButton>(window, "settings.deepseek.mode.budget"); var balance = Find<RadioButton>(window, "settings.deepseek.mode.balance");
            var simple = Find<RadioButton>(window, "settings.deepseek.panel.simple"); var detailed = Find<RadioButton>(window, "settings.deepseek.panel.detailed");
            Check(window.ClientContent.ActualWidth == 780 && window.ClientContent.ActualHeight == 600 && module.IsChecked == true,
                "DeepSeek must retain the original settings canvas and acknowledged module state");
            Check(!Find<Button>(window, "settings.deepseek.sign_in").IsEnabled, "The page must keep the unsupported account connection action disabled");
            Check(Descendants(island).OfType<CompactQuotaGlyph>().All(value => value.RingCount == 0 && value.ShowsPriceClock), "DeepSeek without budgets must show its actual price clock in the header and strip");
            window.CapturePreview(Path.Combine(output, "settings-" + scenario + "-deepseek.png"));
            var suggestion = engine.LatestSnapshot!.Wallet!.Settings!;
            Select(budget); await Until(() => session.Current.DeepSeekMode == "budget" && budget.IsEnabled);
            Check(session.Current.DeepSeekDailyBudget == suggestion.SuggestedDaily && session.Current.DeepSeekWeeklyBudget == suggestion.SuggestedWeekly,
                "First switching to budgets must use the shared Core suggestion");
            Check(engine.LatestSnapshot!.Wallet!.Solo!.Budgets.Count == 2 && Descendants(island).OfType<DeepSeekBudgetDial>().Any(), "Saved amounts must drive the actual solo budget face");
            Check(Descendants(island).OfType<CompactQuotaGlyph>().All(value => value.RingCount == 0 && value.ShowsPriceClock), "The original automatic DeepSeek-only layout retains its clock even with budgets; a budget ring requires an explicit choice");
            daily.Text = "12.50"; Enter(window, daily); await Until(() => session.Current.DeepSeekDailyBudget == 12.5 && daily.IsEnabled);
            weekly.Text = "75"; Enter(window, weekly); await Until(() => session.Current.DeepSeekWeeklyBudget == 75 && weekly.IsEnabled);
            Check(session.Current.DeepSeekDailyBudget == 12.5, "A weekly edit must preserve the independently acknowledged daily amount");
            int beforeInvalid = configurations; daily.Text = "NaN"; Enter(window, daily); await Pump();
            Check(configurations == beforeInvalid && session.Current.DeepSeekDailyBudget == 12.5 && Find<TextBlock>(window, "settings.deepseek.budget.issue").IsVisible,
                "A nonfinite amount must remain an input issue without changing engine or saved settings");
            daily.Text = "12.50"; Enter(window, daily);
            reject = true; daily.Text = "15"; Enter(window, daily); await Until(() => !reject && daily.IsEnabled);
            Check(session.Current.DeepSeekDailyBudget == 12.5 && daily.Text == 12.5.ToString("0.##", CultureInfo.CurrentCulture), "A rejected file write must restore the acknowledged amount in the editor");
            var savedBudget = engine.LatestSnapshot!.Wallet!.Solo!.Budgets.First(value => value.Kind == "day");
            Check(savedBudget.Exceeded || Math.Abs(savedBudget.Fraction * 12.5 + engine.LatestSnapshot.Wallet.Today + engine.LatestSnapshot.Wallet.Elsewhere - 12.5) < 1e-8,
                "Save rollback must restore the actual engine budget, not only the field text");
            Select(Find<RadioButton>(window, "settings.deepseek.ring.week")); await Until(() => session.Current.DeepSeekRingPeriod == "week" && budget.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet!.Settings!.CompactBudgetKind == "week", "The ring period choice must reach the real collapsed budget reading");
            Select(balance); await Until(() => session.Current.DeepSeekMode == "balance" && balance.IsEnabled);
            Check(session.Current.DeepSeekDailyBudget == 12.5 && session.Current.DeepSeekWeeklyBudget == 75 && engine.LatestSnapshot!.Wallet!.Solo!.Budgets.Count == 0,
                "Balance mode must retain saved amounts while suspending their effect");
            Select(budget); await Until(() => session.Current.DeepSeekMode == "budget" && budget.IsEnabled);
            Check(session.Current.DeepSeekDailyBudget == 12.5 && session.Current.DeepSeekWeeklyBudget == 75, "Returning to budgets must restore saved amounts rather than replace them with a new suggestion");
            ulong sequence = engine.LatestSnapshot!.Sequence; int beforeStyle = configurations;
            Select(simple); await Until(() => session.Current.DeepSeekPanelStyle == "simple" && simple.IsEnabled); await island.WaitForPresentationAsync();
            Check(configurations == beforeStyle && engine.LatestSnapshot!.Sequence == sequence && !Descendants(island).OfType<DeepSeekWeekView>().Any() && !Descendants(island).OfType<DeepSeekDistributionView>().Any(),
                "The original simple panel must hide distribution/history without reconfiguring collectors");
            Select(detailed); await Until(() => session.Current.DeepSeekPanelStyle == "detailed" && detailed.IsEnabled); await island.WaitForPresentationAsync();
            Check(configurations == beforeStyle && Descendants(island).OfType<DeepSeekWeekView>().Any(), "Detailed must restore the existing live history without an engine command");
            window.CapturePreview(Path.Combine(output, "settings-" + scenario + "-deepseek-budgets.png"));
            island.CapturePreview(Path.Combine(output, "deepseek-configured-" + scenario + ".png"));
            daily.Text = "0"; Enter(window, daily); await Until(() => session.Current.DeepSeekDailyBudget == null && daily.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet!.Solo!.Budgets.Select(value => value.Kind).SequenceEqual(new[] { "week" }), "Zero must turn off only the daily budget");
            weekly.Text = ""; Enter(window, weekly); await Until(() => session.Current.DeepSeekWeeklyBudget == null && weekly.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet!.Solo!.Budgets.Count == 0 && Descendants(island).OfType<CompactQuotaGlyph>().All(value => value.ShowsPriceClock), "Blank must turn off the last budget and restore the price clock");
            var cost = Find<CheckBox>(window, "settings.deepseek.turn_cost"); Toggle(cost); await Until(() => !session.Current.DeepSeekShowsTurnCost && cost.IsEnabled);
            Check(engine.LatestSnapshot!.Presentation!.Rows.Where(value => value.Provider == "deepseek").All(value => value.Cost == null), "The per-turn display choice must change shared row metadata");
            Toggle(module); await Until(() => session.Current.ProviderModes["deepseek"] == "disabled" && module.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet == null, "A disabled module cannot keep publishing wallet data");
            Toggle(module); await Until(() => session.Current.ProviderModes["deepseek"] == "enabled" && module.IsEnabled);
            var automatic = Find<Button>(window, "settings.deepseek.automatic"); Invoke(automatic); await Until(() => session.Current.ProviderModes["deepseek"] == "automatic" && automatic.Visibility == Visibility.Collapsed);
            await engine.SendAsync("shutdown"); await Until(() => !budget.IsEnabled && !daily.IsEnabled && !module.IsEnabled);
            Check(Find<TextBlock>(window, "settings.deepseek.budget.issue").Visibility == Visibility.Collapsed, "Connection shutdown cannot leave an unrelated amount error");
            Console.WriteLine("PASS DeepSeek settings " + scenario + ": real engine budgets, Core suggestions, independent amount edits, rejection/rollback, period rings, host-only panel style, cost display, module restore and closed-connection controls");
        }
        finally { window.AllowClose = true; window.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); CultureInfo.CurrentUICulture = previous; }
    }
    private static void Enter(Window window, TextBox field) => field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void Select(RadioButton value) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(value).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) { var child = VisualTreeHelper.GetChild(root, index); yield return child; foreach (var value in Descendants(child)) yield return value; } }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed.TotalSeconds < 8) await Task.Delay(20); Check(condition(), "The bounded DeepSeek settings action must finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool value) => true; }
}
