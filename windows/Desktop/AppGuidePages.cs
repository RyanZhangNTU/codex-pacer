using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

public partial class App
{
    private GuideWindow? guideWindow;
    private GuideSession? guides;
    private readonly SemaphoreSlim guideOpening = new(1, 1);
    private async Task BeginGuidesAsync(string[] arguments)
    {
        if (engine == null || settingsSession == null || ui == null) return;
        string version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
        guides = new(settingsSession, input => engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide = input } }, TimeSpan.FromSeconds(3)),
            version, ui.Language, demo, arguments.Contains("--settings"));
        await ShowGuideAsync(arguments.Contains("--welcome"), arguments.Contains("--whats-new"));
    }
    private async Task ShowGuideAsync(bool forceWelcome, bool forceNote = false)
    {
        await guideOpening.WaitAsync();
        try { await ShowGuideCoreAsync(forceWelcome, forceNote); }
        finally { guideOpening.Release(); }
    }
    private async Task ShowGuideCoreAsync(bool forceWelcome, bool forceNote)
    {
        if (quitting || guides == null || ui == null || settingsSession == null || startupRegistration == null) return;
        if (guideWindow != null)
        {
            if (forceWelcome && !guideWindow.IsWelcome) guideWindow.Close();
            else { guideWindow.Activate(); return; }
        }
        try
        {
            var catalog = await guides.LoadAsync(forceWelcome, forceNote);
            if (quitting) return;
            if (catalog.RecordLaunch && await guides.RecordAsync(false) != PreferencesApplyResult.Applied)
                island?.SetStatus(ui.Text("windows.settings.save_failed"));
            if (catalog.Page == null) return;
            GuideWindow? window = null;
            void Settings(string pane)
            {
                window?.Close(); OpenSettings();
                if (settings != null) _ = Navigate(pane);
            }
            async Task Navigate(string pane)
            {
                try
                {
                    if (settings == null) return;
                    if (pane is "codex" or "claude" or "deepseek") await settings.GuideProviderActionAsync(pane);
                    else await settings.NavigateAsync(pane);
                }
                catch (Exception error) when (error is IOException or EngineCommandException or OperationCanceledException)
                { island?.SetStatus(ui.Text("windows.settings.apply_failed")); }
            }
            var content = new GuideContent(ui, settingsSession, startupRegistration, catalog, Settings, () => _ = ShowGuideAsync(true), engine, notifications);
            window = new GuideWindow(ui, content, catalog, demoDark); guideWindow = window;
            window.Closed += async (_, _) =>
            {
                if (ReferenceEquals(guideWindow, window)) guideWindow = null;
                if (!catalog.RecordClose) return;
                try { if (await guides.RecordAsync(catalog.Page == "welcome") != PreferencesApplyResult.Applied) island?.SetStatus(ui.Text("windows.settings.save_failed")); }
                catch (Exception error) when (error is IOException or EngineCommandException or OperationCanceledException) { island?.SetStatus(ui.Text("windows.settings.apply_failed")); }
            };
            window.Show(); window.Activate();
        }
        catch (Exception error) when (error is IOException or EngineCommandException or OperationCanceledException)
        { if (!quitting) island?.SetStatus(ui.Text("windows.settings.apply_failed")); }
    }
}
