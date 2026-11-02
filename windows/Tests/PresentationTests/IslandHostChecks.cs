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
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class IslandHostChecks
{
    internal static async Task Run()
    {
        await using var engine = new EngineClient();
        var opened = new List<string>();
        var apps = new WindowsDesktopApplications(_ => true, value => { opened.Add(value); return true; });
        var window = new IslandWindow(engine, true, false, animationOverride: false, desktopApplications: apps) { IsHitTestVisible = false };
        int settings = 0; window.SettingsRequested += () => settings++;
        try
        {
            window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.Reveal(); await window.WaitForPresentationAsync();
            var buttons = (StackPanel)window.FindName("AppButtons");
            Check(buttons.Visibility == Visibility.Visible && buttons.Children.Count == 2, "Registered Codex and Claude apps must appear when their modules are enabled");
            var codex = buttons.Children.OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "island.open.codex");
            Invoke(codex); await Until(() => opened.Count == 1, "The app action must reach the injected Windows activation service");
            Check(opened.Single() == "OpenAI.Codex_2p2nqsd0c76g0!App", "The app action must activate the allowlisted application identity");
            Check(window.LogicalTarget.Height == 38, "Opening a desktop app must release the expanded island");
            window.Reveal(); await window.SynchronizeExpansionAsync(); await window.WaitForPresentationAsync();
            window.ApplyPreferences(new() { ShowAppButtons = false });
            Check(buttons.Children.Count == 0 && buttons.Visibility == Visibility.Collapsed, "The settings choice must immediately remove desktop app actions");
            await engine.SendAsync("configure", new { providerModes = new { codex = "disabled", claude = "enabled", deepseek = "disabled" } });
            window.ApplyPreferences(new()); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(buttons.Children.Count == 1 && AutomationProperties.GetAutomationId(buttons.Children[0]) == "island.open.claude", "A disabled module cannot retain a desktop app action");
            Invoke((Button)window.FindName("SettingsButton"));
            await Until(() => settings == 1, "The native-size gear action must reach the settings owner");
            await window.WaitForPresentationAsync();
            Check(window.LogicalTarget.Height == 38, "Opening settings must release the expanded island");
            var shell = (Border)window.FindName("Shell");
            foreach (string position in new[] { "topLeft", "bottomLeft", "topRight", "bottomRight", "center" })
            {
                window.ApplyPreferences(new() { Position = position, PositionChosen = true, DisplayMode = "floating" });
                await window.WaitForPresentationAsync();
                Check(position == "center" ? window.VisibleHeight == 38 : window.VisibleWidth == 32,
                    "Live position changes must switch between the native capsule and strip dimensions");
                var corners = shell.CornerRadius;
                Check(position.EndsWith("Left", StringComparison.Ordinal) ? corners.TopLeft == 0 && corners.BottomLeft == 0
                    : position.EndsWith("Right", StringComparison.Ordinal) ? corners.TopRight == 0 && corners.BottomRight == 0 : corners.TopLeft > 0,
                    "The screen-side corners must stay flat at each selected edge");
            }
            window.ApplyPreferences(new() { Position = "bottomRight", PositionChosen = true, DisplayMode = "notch" });
            await window.WaitForPresentationAsync();
            Check(window.LogicalTarget.Y == 0 && window.VisibleHeight == 32 && ((Grid)window.FindName("Header")).Visibility == Visibility.Visible
                && shell.CornerRadius.TopLeft == 0 && shell.CornerRadius.TopRight == 0,
                "Forced notch mode must attach at the screen top and ignore the saved corner");
            window.ApplyPreferences(new() { Position = "bottomRight", PositionChosen = true, DisplayMode = "floating" });
            await window.WaitForPresentationAsync();
            Check(window.VisibleWidth == 32 && ((Grid)window.FindName("Strip")).Visibility == Visibility.Visible,
                "Returning to custom mode must restore the saved side strip");
            Console.WriteLine("PASS island host: desktop app preference, module filtering, allowlisted activation and settings action");
        }
        finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
    }
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
