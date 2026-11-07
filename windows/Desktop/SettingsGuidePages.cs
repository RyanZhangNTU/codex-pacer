using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private int guideRevision;
    private GuideContent? guideContent;
    internal event Action? WelcomeRequested;
    private static bool ReadOnlyGuidePane(string pane) => pane is "support";
    private void ClearGuidePages() { guideRevision++; guideContent = null; }
    /// Help & Updates: the update card, then What's New or Help under one segmented choice.
    private void BuildAbout()
    {
        BuildUpdateCard();
        // A compact segmented choice, left-aligned, as on the Mac.
        var tabs = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (string tab in new[] { "whatsNew", "help" })
        {
            string name = ui.Text(tab == "whatsNew" ? "whats_new.window_title" : "settings.pane.help");
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), Content = name, GroupName = "settings.about", IsChecked = aboutTab == tab };
            Identify(choice, "settings.about." + tab, name);
            choice.Checked += (_, _) =>
            {
                if (synchronizing || aboutTab == tab) return;
                aboutTab = tab;
                // Rebuild after the click finishes; the choice itself is replaced.
                Dispatcher.BeginInvoke(() => { if (!sourceClosed && activePane == "about" && aboutTab == tab) RebuildPane("about"); });
            };
            tabs.Children.Add(choice);
        }
        var segments = new Border { Child = tabs, Padding = new Thickness(2), CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 2, 0, 14), HorizontalAlignment = HorizontalAlignment.Left };
        segments.SetResourceReference(Border.BackgroundProperty, "SettingsButton");
        AutomationProperties.SetAutomationId(segments, "settings.about.tabs"); form.Children.Add(segments);
        BuildGuidePage(aboutTab);
    }
    private void BuildGuidePage(string kind)
    {
        int revision = ++guideRevision; string pane = activePane;
        var pending = Detail(ui.Text("claude.account.checking")); form.Children.Add(pending);
        _ = Load();
        async Task Load()
        {
            try
            {
                await sourceReady.WaitAsync(TimeSpan.FromSeconds(3));
                var client = engine ?? ShellProjection.Client;
                if (client == null) throw new IOException();
                var catalog = await client.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide = new GuideRequest(Version, session.Current.WhatsNewVersion,
                    session.Current.WelcomeGuideVersion, ui.Language, demo, true, false, false) } }, TimeSpan.FromSeconds(3));
                if (sourceClosed || revision != guideRevision || pane != activePane) return;
                form.Children.Remove(pending);
                guideContent = new(ui, session, startup, catalog, value => _ = NavigateAsync(value), () => WelcomeRequested?.Invoke(), client, notifications, guideLinkLauncher, copyLink: guideCopyLink);
                form.Children.Add(guideContent);
                if (kind == "help") guideContent.Help(); else if (kind == "support") guideContent.Support(); else guideContent.SettingsReleases(catalog.History);
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException or TimeoutException)
            { if (!sourceClosed && revision == guideRevision) pending.Text = ui.Text("windows.settings.apply_failed"); }
        }
    }
    internal async Task GuideProviderActionAsync(string provider)
    {
        await NavigateAsync(provider); await sourceReady;
        if (sourceClosed || engine == null) return;
        if (provider == "claude" && engine.LatestSnapshot?.ClaudeConnection is { } claude)
        {
            if (claude.State == "workspaceNeeded") await OpenClaudeAccountMenu(true);
            else if (claude.State == "signedOut" && claudeConnection != null) await claudeConnection.ConnectAsync(claude.Context);
        }
        else if (provider == "deepseek" && engine.LatestSnapshot?.DeepseekConnection is { Mode: not "apiKey" } deepseek && webConnection != null)
            await webConnection.ConnectAsync(deepseek.Context);
    }
}
