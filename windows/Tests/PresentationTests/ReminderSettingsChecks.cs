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

internal static class ReminderSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        var oldCulture = CultureInfo.CurrentCulture; CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(language);
        await using var engine = new EngineClient(); int configurations = 0, systemSettingsOpened = 0; bool reject = false;
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "reminders" };
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => { if (reject) { reject = false; return false; } return true; });
        var system = new Notifications();
        using var notifications = new NotificationSession(session, system, value => Application.Current.Dispatcher.InvokeAsync(value), _ => { }, true);
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { IsHitTestVisible = false, ShowActivated = false };
        session.Changed += island.ApplyPreferences;
        SettingsWindow Make() => new(UiText.For(language == "zh-Hans"), session, new Startup(), true, dark, engine, notifications: notifications,
            openNotificationSettings: () => systemSettingsOpened++) { IsHitTestVisible = false, ShowActivated = false };
        var window = Make(); string scenario = language + (dark ? "-dark" : "-light");
        try
        {
            window.Show(); island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, preferences.EngineConfiguration(), referenceFixture: true);
            island.Reveal(); await island.WaitForPresentationAsync(); await Pump();
            var low = Find<TextBox>(window, "settings.reminders.lowLine"); var spike = Find<TextBox>(window, "settings.reminders.spikeLine");
            var lowSwitch = Find<CheckBox>(window, "settings.reminders.lowBalance"); var budget = Find<CheckBox>(window, "settings.reminders.budget");
            Check(window.ClientContent.ActualWidth == 780 && window.ClientContent.ActualHeight == 600 && low.Tag is string { Length: > 0 } && spike.Tag is string { Length: > 0 }, "Reminder geometry and automatic thresholds follow the original page and Core rules");
            Check(!Find<CheckBox>(window, "settings.reminders.ssh").IsEnabled && Find<CheckBox>(window, "settings.reminders.fiveHour").IsEnabled, "Working quota reminders and pending SSH monitoring are distinguished");
            window.CapturePreview(Path.Combine(output, "settings-" + scenario + "-reminders.png"));
            low.Text = "90"; Enter(window, low); await Until(() => session.Current.DeepSeekLowBalanceLine == 90 && low.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet?.Alert?.Kind == "lowBalance", "The saved threshold changes the real wallet state");
            var warnings = (CompactWarningsView)island.FindName("WarningGlyphs");
            Check(warnings.Visibility == Visibility.Visible && warnings.Children.OfType<Border>().All(value => value.ActualHeight == 13), "The live capsule retains its 13-point height");
            var peer = UIElementAutomationPeer.CreatePeerForElement(warnings);
            Check(peer?.GetAutomationControlType() == AutomationControlType.Group && peer.GetChildren() is not { Count: > 0 } && peer.GetName().Contains("DeepSeek"), "The warning slot exposes one summary without duplicate glyph names");
            Toggle(lowSwitch); await Until(() => !session.Current.WarningKinds.Contains("lowBalance") && lowSwitch.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet?.Alert == null, "Turning a warning off changes the live header");
            low.Text = "2.5"; Enter(window, low); spike.Text = "7.25"; Enter(window, spike);
            await Until(() => session.Current.DeepSeekLowBalanceLine == 2.5 && session.Current.DeepSeekSpikeLimit == 7.25 && spike.IsEnabled);
            int before = configurations; spike.Text = "NaN"; Enter(window, spike); await Pump();
            Check(configurations == before && Find<TextBlock>(window, "settings.reminders.amount.issue").Visibility == Visibility.Visible, "Invalid money input does not reach the engine");
            spike.Text = ""; Enter(window, spike); await Until(() => session.Current.DeepSeekSpikeLimit == null && spike.IsEnabled);
            reject = true; low.Text = "43"; Enter(window, low); await Until(() => low.IsEnabled && low.Text == "2.5");
            Check(session.Current.DeepSeekLowBalanceLine == 2.5 && engine.LatestSnapshot!.Wallet?.State == "normal", "A failed save restores the acknowledged threshold and field");
            var wallet = engine.LatestSnapshot!.Wallet!; double spent = wallet.Today + wallet.Elsewhere;
            await session.ChangeAsync(p => p with { DeepSeekMode = "budget", DeepSeekDailyBudget = spent / 0.9, DeepSeekWeeklyBudget = null }); await Pump();
            Check(engine.LatestSnapshot!.Wallet?.Alert?.Kind == "nearingBudget", "A budget crossing reaches the compact warning slot");
            Toggle(budget); await Until(() => !session.Current.WarningKinds.Contains("budget") && budget.IsEnabled);
            Check(engine.LatestSnapshot!.Wallet?.Alert == null, "The budget switch controls the live alert");
            var retention = Find<ComboBox>(window, "settings.reminders.retention"); retention.SelectedValue = 0;
            await Until(() => session.Current.RetentionMinutes == 0 && retention.IsEnabled);
            var systemSwitch = Find<CheckBox>(window, "settings.reminders.notifications"); system.Result = NotificationAvailability.Denied;
            before = configurations; Toggle(systemSwitch); await Until(() => !notifications.IsChanging);
            Check(!session.Current.SystemNotifications && systemSwitch.IsChecked == false && Find<TextBlock>(window, "settings.reminders.notifications.issue").Visibility == Visibility.Visible, "Native denial resets the switch and explains the Windows setting");
            var systemSettings = Find<Button>(window, "settings.reminders.notifications.settings");
            var settingsPeer = new ButtonAutomationPeer(systemSettings);
            Check(systemSettings.Focusable && settingsPeer.GetName().Contains(UiText.For(language == "zh-Hans").Text("settings.system_notifications")),
                "The system settings link remains keyboard accessible and names the notification setting");
            ((IInvokeProvider)settingsPeer.GetPattern(PatternInterface.Invoke)).Invoke(); await Pump();
            Check(systemSettingsOpened == 1 && configurations == before, "The native settings entry opens once without changing collectors");
            system.Result = NotificationAvailability.Available; Toggle(systemSwitch); await Until(() => session.Current.SystemNotifications && !notifications.IsChanging);
            Check(configurations == before, "System notification choices do not reconfigure collectors");
            Toggle(systemSwitch); await Until(() => !session.Current.SystemNotifications && !notifications.IsChanging);
            var pending = new TaskCompletionSource<NotificationAvailability>(TaskCreationOptions.RunContinuationsAsynchronously); system.Pending = pending.Task;
            Toggle(systemSwitch); window.AllowClose = true; window.Close(); pending.SetResult(NotificationAvailability.Available);
            await Until(() => session.Current.SystemNotifications && !notifications.IsChanging);
            window = Make(); window.Show(); await Pump();
            Check(Find<CheckBox>(window, "settings.reminders.notifications").IsChecked == true, "Registration survives settings-window closure and reopening");
            Check(system.Deliveries == 0, "Synthetic UI checks cannot emit real notifications");
            await engine.SendAsync("shutdown"); await Until(() => !Find<TextBox>(window, "settings.reminders.lowLine").IsEnabled);
            Check(!Find<ComboBox>(window, "settings.reminders.retention").IsEnabled, "Closed engine controls cannot claim to apply edits");
            Console.WriteLine("PASS reminders " + scenario + ": Core thresholds, warning capsules, UIA summary, independent edits/rollback, retention, native denial, host-only notification switch and settings reopen");
        }
        finally { window.AllowClose = true; window.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); CultureInfo.CurrentCulture = oldCulture; }
    }
    private static void Enter(Window window, TextBox field) => field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) { var child = VisualTreeHelper.GetChild(root, index); yield return child; foreach (var value in Descendants(child)) yield return value; } }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed.TotalSeconds < 8) await Task.Delay(20); Check(condition(), "The reminder settings action must finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool value) => true; }
    private sealed class Notifications : ISystemNotifications
    {
        public event Action<string>? Activated { add { } remove { } }
        internal NotificationAvailability Result = NotificationAvailability.Available;
        internal Task<NotificationAvailability>? Pending;
        internal int Deliveries;
        public Task<NotificationAvailability> EnableAsync() => Pending ?? Task.FromResult(Result);
        public Task DisableAsync() => Task.CompletedTask;
        public Task ClearAsync() => Task.CompletedTask;
        public bool Deliver(NotificationContent content) { Deliveries++; return true; }
        public void Dispose() { }
    }
}
