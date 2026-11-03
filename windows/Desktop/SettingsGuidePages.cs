using System;
using System.IO;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private int guideRevision;
    private GuideContent? guideContent;
    internal event Action? WelcomeRequested;
    private static bool ReadOnlyGuidePane(string pane) => pane is "help" or "support";
    private void ClearGuidePages() { guideRevision++; guideContent = null; }
    private void BuildGuidePage()
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
                if (pane == "help") guideContent.Help(); else if (pane == "support") guideContent.Support(); else guideContent.Releases(catalog.History);
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
