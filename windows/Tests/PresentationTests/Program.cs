using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
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

internal static class Program
{
    private static readonly List<string> Errors = [];
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--fullscreen-fixture"]) return FullscreenFixture.Run();
        int fixture = Array.IndexOf(args, "--language");
        if (fixture >= 0) return SlowEngineChecks.Fixture(args[fixture + 1]);
        if (args is ["--unit-only"])
        {
            try { SystemAppearanceUnitChecks.Run(); return 0; }
            catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
        string output = args.Length > 0 ? Path.GetFullPath(args[0]) : Path.Combine(Path.GetTempPath(), "pacer-presentation-tests");
        string group = args.Length > 1 ? args[1] : "all";
        string? desktop = args.Length > 2 ? Path.GetFullPath(args[2]) : null;
        Directory.CreateDirectory(output);
        int result = 1;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown,
            Resources = new ResourceDictionary { Source = new Uri("/CodexPacer;component/PacerTheme.xaml", UriKind.Relative) } };
        app.DispatcherUnhandledException += (_, error) =>
        {
            Errors.Add(error.Exception.ToString()); Console.Error.WriteLine(error.Exception);
            error.Handled = true; app.Shutdown(1);
        };
        PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
        PresentationTraceSources.DataBindingSource.Listeners.Add(new BindingErrors());
        app.Startup += async (_, _) =>
        {
            await using var projections = new EngineClient();
            try
            {
                await projections.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
                ShellProjection.Client = projections;
                if (group is "all" or "recovery" or "persistence") await StorageRecoveryChecks.Run();
                SystemAppearanceUnitChecks.Run(); TypographyChecks.Run(); TimingBindingChecks.Run(); await QuotaChartBridgeChecks.Run();
                if (group is "all" or "responsive") { await SlowEngineChecks.Run(); await PreferencesResponsivenessChecks.Run(); }
                if (group == "persistence") await PreferencesResponsivenessChecks.Run();
                bool All(string name) => group == "all" || group == name;
                if (All("quota"))
                {
                    await QuotaProjectionChecks.Run(); await ClassicQuotaChecks.Run(output); await SingleQuotaChecks.Run(output);
                    await LegacyQuotaChecks.Run(output); await QuotaConnectionChecks.Run(output); await TypographyLocaleChecks.Run(output);
                }
                if (All("web")) { await ProviderWebStartupChecks.Run(); await ClaudeWebSessionChecks.Run(); await DeepSeekWebSessionChecks.Run(); }
                if (group == "deepseek") { await ClaudeConnectionChecks.Run("zh-Hans", true, output); await DeepSeekWebConnectionChecks.Run("en", false, output); }
                if (All("host")) { await NotificationActivationWindowChecks.Run(); await IslandHostChecks.Run(); await BackdropPresentationChecks.Run(); }
                if (All("idle")) { await IdleSchedulingChecks.Run(); await OcclusionSchedulingChecks.Run(); }
                if (All("display")) { await DisplayWindowChecks.Run(output); if (group != "all") await OcclusionSchedulingChecks.Run(); }
                foreach (string language in new[] { "en", "zh-Hans" })
                {
                    if (All("accessibility")) { AccessibleNumberChecks.Run(language); await AccessibilityChecks.Run(language); }
                    foreach (bool motion in new[] { false, true })
                    {
                        if (All("island")) await Run(language, motion, output);
                        if (All("conversation")) foreach (string provider in new[] { "codex", "claude" }) await ConversationNavigationChecks.Run(provider, language, motion);
                        if (All("harness")) await HarnessNavigationChecks.Run(language, motion, output);
                        if (All("quota")) { await ClassicLayoutChecks.Run(language, output, motion); await DeepSeekSoloChecks.Run(language, motion, output); }
                    }
                    foreach (bool dark in new[] { false, true })
                    {
                        if (group == "persistence")
                        {
                            await PersistentSettingsChecks.Run(language, dark, output, desktop ?? throw new ArgumentException("Supply the desktop executable for restart checks."));
                            await QuotaHistoryChecks.Run(language, dark, output); await ProviderHistoryChecks.Run(language, dark, output);
                        }
                        if (group == "deepseek") { await DeepSeekSettingsChecks.Run(language, dark, output); await ReminderSettingsChecks.Run(language, dark, output); }
                        if (All("display") || group == "displaySettings") await DisplaySettingsChecks.Run(language, dark);
                        if (All("pages")) await GuidePageChecks.Run(language, dark, output);
                        if (All("settings"))
                        {
                            await PersistentSettingsChecks.Run(language, dark, output, desktop ?? throw new ArgumentException("Supply the desktop executable for restart checks."));
                            await SettingsPresentationChecks.Run(language, dark, output); await CodexSettingsChecks.Run(language, dark, output);
                            foreach (string provider in new[] { "claude", "deepseek" }) await ProviderHomeSettingsChecks.Run(provider, language, dark, output);
                            await DeepSeekSettingsChecks.Run(language, dark, output); await ReminderSettingsChecks.Run(language, dark, output);
                        }
                        if (All("collapsed")) foreach (bool motion in new[] { false, true }) await CollapsedLayoutChecks.Run(language, dark, motion, output);
                        if (All("quota")) { await QuotaHistoryChecks.Run(language, dark, output); await ProviderHistoryChecks.Run(language, dark, output); }
                        if (All("connection"))
                        {
                            await ClaudeConnectionChecks.Run(language, dark, output); await DeepSeekConnectionChecks.Run(language, dark, output);
                            await DeepSeekWebConnectionChecks.Run(language, dark, output);
                        }
                    }
                }
                Check(Errors.Count == 0, "WPF binding/runtime errors: " + string.Join("\n", Errors));
                Console.WriteLine("All functional presentation checks passed."); result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally { ShellProjection.Client = null; await projections.DisposeAsync(); app.Shutdown(); }
        };
        app.Run(); return result;
    }
    private static async Task Run(string language, bool motion, string output)
    {
        await using var engine = new EngineClient();
        // Absolute reference geometry uses one logical viewport. The HWND
        // still renders at the actual monitor DPI.
        var window = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: motion,
            screenGeometry: () => (new(0, 0, 2560, 1440), new(0, 0, 2560, 1400)));
        // Keep the real desktop pointer from steering UI Automation scenarios.
        // Explicit routed hover/key events below still use the window handlers.
        window.IsHitTestVisible = false;
        string scenario = language + (motion ? "-motion" : "-reduced");
        EngineSnapshot? latest = null;
        engine.Snapshot += value => Volatile.Write(ref latest, value);
        try
        {
            window.Show();
            Check(WindowRendering.Mode(window) == "Default", "The layered island must retain its existing rendering mode");
            window.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseEnterEvent });
            await window.WaitForPresentationAsync();
            Check(double.IsFinite(window.VisibleWidth) && window.VisibleHeight > 38,
                "Hover before the first engine snapshot must have finite placeholder layout");
            window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent });
            await window.WaitForPresentationAsync();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            await Until(() => latest?.Wallet?.Balance != null, "The reference window must receive its completed demo wallet");
            var withQuota = await NativeCompactBar.Shared.EditAsync(new DesktopPreferences { IslandAppearance = "classic" }, language,
                NativeCompactBar.Providers(new DesktopPreferences { IslandAppearance = "classic" }, engine.LatestSnapshot), new("show", "quota"));
            window.ApplyPreferences(withQuota);
            await window.SynchronizeExpansionAsync();
            await Pump();
            await window.WaitForPresentationAsync();
            var title = (TextBlock)window.FindName("TasksTitle");
            UiText ui = UiText.For(language == "zh-Hans");
            Check(title.Text == ui.Text("layout.group.tasks")
                && ((TextBlock)window.FindName("QuotaTitle")).Text == ui.Text("layout.group.quota_balance")
                && new ButtonAutomationPeer((Button)window.FindName("MarkReadButton")).GetName() == ui.Text("activity.mark_all_read"),
                "Visible section titles and accessible controls must use the shared language catalog");
            Check(new Typeface(title.FontFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal).TryGetGlyphTypeface(out GlyphTypeface glyph)
                && glyph.FamilyNames.Values.Any(name => name.StartsWith("Inter", StringComparison.Ordinal)), "The embedded Inter face must resolve without a fallback font");
            var boundProjection = await NativeCompactBar.Shared.ReadAsync(withQuota, language,
                NativeCompactBar.Providers(withQuota, engine.LatestSnapshot), engine.LatestSnapshot?.CompactContext);
            Check(boundProjection.Components.Single(value => value.Id == "quota").Entries.Length > 0,
                "Protocol v1 snapshots without optional modules must retain their projected quota entries");
            var quotaLabel = (AlternatingQuotaText)window.FindName("QuotaLabel");
            double quotaRight = quotaLabel.TranslatePoint(new Point(quotaLabel.ActualWidth, 0), (FrameworkElement)window.FindName("Shell")).X;
            Check(quotaRight <= window.VisibleWidth - 14 && quotaLabel.ActualWidth > 0,
                $"The collapsed header must reserve its widest value without clipping (right={quotaRight}, width={window.VisibleWidth}, slot={quotaLabel.ActualWidth}, dpi={VisualTreeHelper.GetDpi(window).PixelsPerInchX}, mode={motion}, systemAnimations={SystemParameters.ClientAreaAnimation})");
            Check(window.LogicalTarget.Width > 0 && window.LogicalTarget.Height == 38
                && window.VisibleSizeMatches(window.LogicalTarget.Width, window.LogicalTarget.Height),
                "The measured collapsed header must bind the shared target without clipping");
            await IslandSurfaceChecks.Run(window);
            var host = (RevealHost)window.FindName("Expanded");
            var expansion = (IExpandCollapseProvider)UIElementAutomationPeer.CreatePeerForElement(window).GetPattern(PatternInterface.ExpandCollapse);
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Collapsed, "The island must expose its collapsed UIA state independently of its retained native canvas");
            var peer = UIElementAutomationPeer.CreatePeerForElement(host);
            Check(peer.GetChildren()?.Count is null or 0, "Collapsed content must be absent from the accessibility tree");
            window.Reveal();
            await window.WaitForPresentationAsync(); await Pump();
            Check(peer.GetChildren()?.Count > 0, $"Revealed content must be accessible (height={window.VisibleHeight}, opacity={host.Opacity}, control={peer.IsControlElement()}, {window.PresentationDiagnostics})");
            string[] dialNames = Descendants<QuotaDial>(window).Select(dial => UIElementAutomationPeer.CreatePeerForElement(dial).GetName()).ToArray();
            Check(dialNames.Any(name => name.Contains("43%")) && dialNames.Any(name => name.Contains("81%") && name.Contains("64%")) && dialNames.Any(name => name.Contains("¥86")),
                "Vector dials must expose their actual quota and wallet values to accessibility clients");
            for (int stage = 0; stage <= 3; stage++)
            {
                await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = stage }, waitForSnapshot: stage != 0);
                await window.WaitForPresentationAsync();
                await Until(() => ((Grid)window.FindName("TaskPages")).Children.Count == 1,
                    "The stage change must retire its outgoing task page");
                string[] expected = latest!.Presentation!.Rows.Take(latest.Presentation.PageSize).Select(row => row.Id).ToArray();
                string[] actual = Descendants<TaskRow>(window).Select(row => ((TaskRowState)row.DataContext).Value.Id).ToArray();
                Check(actual.SequenceEqual(expected), $"Stage {stage} rows must match the shared engine projection: {string.Join(",", actual)}");
                Check(Errors.Count == 0, "Every task stage must bind without runtime errors");
            }
            Check(latest?.CapturedAt == 1_800_000_000 && window.LogicalTarget.Width == 404 && window.LogicalTarget.Height == 440 && window.VisibleSizeMatches(404, 440),
                "The original synthetic clock and settled 404×440 geometry");
            await IslandSurfaceChecks.Run(window);
            Console.WriteLine("PASS " + scenario + ": shared row order, four states, bindings and reveal accessibility");

            var reversalFrames = new List<MotionFrame>();
            void Frame(MotionFrame value) => reversalFrames.Add(value);
            window.FrameApplied += Frame;
            for (int turn = 0; turn < 4; turn++)
            {
                int closingStart = reversalFrames.Count;
                window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent });
                if (motion) await Until(() => reversalFrames.Skip(closingStart).Any(frame => !frame.Finished && frame.ExpansionVelocity < 0 && frame.Expansion is > 0 and < 0.85), "A close must display an intermediate negative-velocity frame before reversing");
                int openingStart = reversalFrames.Count;
                window.Reveal();
                if (motion) await Until(() => reversalFrames.Skip(openingStart).Any(frame => !frame.Finished && frame.ExpansionVelocity > 0), "A reversed open must display an intermediate positive-velocity frame");
                await Pump();
            }
            await window.WaitForPresentationAsync(); await Pump(); window.FrameApplied -= Frame;
            Check(motion ? reversalFrames.Count >= 8 && reversalFrames.Count(frame => frame.ExpansionVelocity < 0) >= 4 && reversalFrames.Count(frame => frame.ExpansionVelocity > 0) >= 4
                    : reversalFrames.Count >= 8 && reversalFrames.All(frame => frame.Finished && frame.ExpansionVelocity == 0),
                $"Actual window callbacks must show both directions during rapid reversals; count={reversalFrames.Count}, negative={reversalFrames.Count(frame => frame.ExpansionVelocity < 0)}, positive={reversalFrames.Count(frame => frame.ExpansionVelocity > 0)}");
            double anchor = reversalFrames[0].Window.X + reversalFrames[0].Window.Width / 2;
            Check(reversalFrames.All(frame => Math.Abs(frame.Window.X + frame.Window.Width / 2 - anchor) < 0.51 && Math.Abs(frame.Window.Y - 10) < 0.01),
                "Rapid reversals must keep the top-centre anchor fixed");
            Check(window.LogicalTarget.Height == 440 && window.VisibleSizeMatches(404, 440) && host.Opacity == 1 && peer.GetChildren()?.Count > 0,
                "The actual window must settle and restore accessibility after rapid reversals");
            Console.WriteLine("PASS " + scenario + ": frame callbacks, motion policy, fixed anchor and convergence");

            var badge = (ActivityBadge)window.FindName("Badge");
            EngineHeader idle = latest!.Presentation!.Header with { Attention = null, Ending = null, EndingIsCore = false };
            badge.Update(idle, motion);
            var attention = idle with { Attention = "approval" };
            badge.Update(attention, motion); await Pump();
            Check(badge.TransientMotion.Ripple == motion, "New attention must play the native ripple only when motion is enabled");
            var completed = idle with { Ending = "checkmark.circle", EndingProvider = "codex", EndingIsCore = false };
            badge.Update(completed, motion); await Pump();
            if (motion) await Until(() => badge.TransientMotion.Bloom && badge.TransientMotion.Scale > 1.1,
                "New endings must display the measured native bloom through the actual animation clock");
            else Check(!badge.TransientMotion.Bloom && badge.TransientMotion.Scale == 1, "Reduced motion must keep the ending static");
            await Until(() => !badge.TransientMotion.Ripple && !badge.TransientMotion.Bloom, "The native transient clocks must finish naturally"); await Pump();
            Check(!badge.TransientMotion.Ripple && !badge.TransientMotion.Bloom,
                "The two native ripples and finite bloom must finish without recurring timers");
            badge.Update(completed, motion); await Pump();
            Check(!badge.TransientMotion.Ripple && !badge.TransientMotion.Bloom, "Repeated snapshots must not replay a notification");
            badge.Update(idle, motion); badge.Update(attention, motion); badge.Update(completed, motion);
            badge.Update(completed, false); await Pump();
            Check(!badge.TransientMotion.Ripple && !badge.TransientMotion.Bloom && badge.TransientMotion.Scale == 1,
                "Enabling reduced motion must cancel existing transient clocks");
            badge.Update(latest!.Presentation!.Header, motion);
            Console.WriteLine("PASS " + scenario + ": finite badge motion, completion, snapshot stability and motion policy");

            await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = 0 });
            await window.WaitForPresentationAsync();
            var slots = (Grid)window.FindName("QuotaSlots");
            double originalTop = slots.TranslatePoint(new Point(), window).Y;
            Invoke((Button)window.FindName("NextPage"));
            await Until(() => ((TextBlock)window.FindName("PageNumber")).Text == "2 / 3", "The next-page action must update the logical page");
            var pages = (Grid)window.FindName("TaskPages");
            foreach (var outgoing in pages.Children.OfType<RevealHost>().SkipLast(1))
                Check(UIElementAutomationPeer.CreatePeerForElement(outgoing).GetChildren()?.Count is null or 0,
                    "A fading old page must leave the accessibility tree before its visual is removed");
            await Until(() => pages.Children.Count == 1, "The real page transition must release its outgoing visual"); await Pump();
            string[] second = Descendants<TaskRow>(window).Select(row => ((TaskRowState)row.DataContext).Value.Id).ToArray();
            Check(second.Length == 3 && second.SequenceEqual(latest!.Presentation!.Rows.Skip(3).Take(3).Select(row => row.Id)),
                "Second page must show the next three families; actual=" + string.Join(",", second) + "; expected=" +
                string.Join(",", latest!.Presentation!.Rows.Skip(3).Take(3).Select(row => row.Id)) + "; label=" + ((TextBlock)window.FindName("PageNumber")).Text);
            Invoke((Button)window.FindName("NextPage"));
            await Until(() => ((TextBlock)window.FindName("PageNumber")).Text == "3 / 3" && pages.Children.Count == 1,
                "The last page must finish its actual transition"); await Pump();
            Check(Descendants<TaskRow>(window).Count() == 1, "The last page must show its one remaining task");
            Check(Math.Abs(slots.TranslatePoint(new Point(), window).Y - originalTop) < 0.01, "The quota section must not jump on the last page");
            Check(!((Button)window.FindName("NextPage")).IsEnabled, "Next is disabled at the last page");
            Console.WriteLine("PASS " + scenario + ": accessible pagination, fixed row capacity and last-page bounds");

            await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = 3 });
            await window.WaitForPresentationAsync();
            var markRead = (Button)window.FindName("MarkReadButton");
            Check(markRead.IsEnabled, "Unread endings must enable the read action");
            ulong before = latest!.Sequence;
            Invoke(markRead);
            await Until(() => latest!.Sequence > before, "The read action must reach the engine"); await Pump();
            await Until(() => !latest!.Presentation!.Rows.Any(row => row.Unread && row.Phase is "completed" or "interrupted"),
                "The mark-read snapshot must finish before checking the model");
            Check(!latest!.Presentation!.Rows.Any(row => row.Unread && row.Phase is "completed" or "interrupted"), "Read actions must update the visible model");
            window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent });
            await window.WaitForPresentationAsync(); await Pump();
            Check(window.LogicalTarget.Height == 38 && window.VisibleSizeMatches(window.LogicalTarget.Width, 38) && peer.GetChildren()?.Count is null or 0, "Escape must close the panel and hide its accessibility descendants");
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Collapsed, "Escape must publish the collapsed UIA state");
            window.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseEnterEvent });
            await window.WaitForPresentationAsync();
            Check(window.LogicalTarget.Height == 440 && window.VisibleSizeMatches(404, 440) && peer.GetChildren()?.Count > 0, "Hover must reopen an unpinned panel after Escape");
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Expanded, "Hover must publish the expanded UIA state");
            var hoverExit = Stopwatch.StartNew();
            window.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseLeaveEvent });
            await Until(() => window.VisibleHeight < 440, "Hover exit must start the native delayed close");
            Check(hoverExit.Elapsed >= TimeSpan.FromMilliseconds(380), "Hover exit must retain the native 0.4-second grace period");
            await window.WaitForPresentationAsync();
            Check(window.LogicalTarget.Height == 38 && window.VisibleSizeMatches(window.LogicalTarget.Width, 38) && peer.GetChildren()?.Count is null or 0, "Hover exit must settle and remove expanded accessibility");
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Collapsed, "Hover exit must publish the collapsed UIA state");
            expansion.Expand(); await window.WaitForPresentationAsync();
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Expanded && window.LogicalTarget.Height == 440, "The UIA Expand action must reveal the panel");
            expansion.Collapse(); await window.WaitForPresentationAsync();
            Check(expansion.ExpandCollapseState == ExpandCollapseState.Collapsed && window.LogicalTarget.Height == 38, "The UIA Collapse action must clear the pin and close the panel");
            Console.WriteLine("PASS " + scenario + ": read action, Escape, hover reopening/exit and accessibility cleanup");
            window.Reveal(); await window.WaitForPresentationAsync(); await Pump();
            window.CapturePreview(Path.Combine(output, "presentation-" + scenario + ".png"));
            Console.WriteLine("Window timing " + scenario + ": " + window.PresentationDiagnostics);
        }
        catch
        {
            Console.WriteLine("Window fixture startup state: " + JsonSerializer.Serialize(new
            {
                callbackSequence = latest?.Sequence, engineSequence = engine.LatestSnapshot?.Sequence,
                callbackHasBalance = latest?.Wallet?.Balance != null, engineHasBalance = engine.LatestSnapshot?.Wallet?.Balance != null,
                walletState = engine.LatestSnapshot?.Wallet?.State,
                source = engine.LatestSnapshot?.DeepseekConnection?.Source, mode = engine.LatestSnapshot?.DeepseekConnection?.Mode,
                refreshing = engine.LatestSnapshot?.DeepseekConnection?.Refreshing,
                connected = engine.LatestSnapshot?.DeepseekConnection?.Reading.Connected,
                action = engine.LatestSnapshot?.DeepseekConnection?.Reading.Action,
                initialized = engine.IsInitialized, closed = engine.IsConnectionClosed
            }));
            Console.WriteLine(window.PresentationDiagnostics);
            foreach (string field in new[] { "compactRow", "compactColumn" })
                if (typeof(IslandWindow).GetField(field, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.GetValue(window) is Dictionary<string, Button> slots)
                    Console.WriteLine("Synthetic compact state " + field + ": " + JsonSerializer.Serialize(slots.Select(item => new
                    {
                        component = item.Key, visible = item.Value.IsVisible, opacity = item.Value.Opacity,
                        baseOpacity = item.Value.GetAnimationBaseValue(UIElement.OpacityProperty),
                        dims = item.Value.Tag is true, animated = item.Value.HasAnimatedProperties
                    })));
            try { window.CapturePreview(Path.Combine(output, "failed-" + scenario + ".png")); }
            catch (Exception captureError) { Console.WriteLine("Diagnostic capture unavailable: " + captureError.Message); }
            throw;
        }
        finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
    }
    private static void Invoke(Button button)
    {
        var peer = new ButtonAutomationPeer(button);
        ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T typed) yield return typed;
            foreach (T nested in Descendants<T>(child)) yield return nested;
        }
    }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(25);
        Check(condition(), message);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class BindingErrors : TraceListener
    {
        public override void Write(string? message) { if (message != null) Errors.Add(message); }
        public override void WriteLine(string? message) { if (message != null) Errors.Add(message); }
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
