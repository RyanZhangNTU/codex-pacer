using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private TextBox? providerHomeField;
    private Expander? providerHomeLocations;
    private TextBlock? providerHomeIssue;
    private Button? providerHomeChoose;
    private string? homeProvider, homeSaved, homePending, homeInspectionKey;
    private long homePaneRevision, homeFieldRevision;
    private Task homeInspection = Task.CompletedTask;
    private void ClearProviderHome()
    {
        homePaneRevision++; homeFieldRevision++; homeProvider = homeSaved = homePending = homeInspectionKey = null;
        providerHomeField = null; providerHomeLocations = null; providerHomeIssue = null; providerHomeChoose = null; homeInspection = Task.CompletedTask;
    }
    private string SavedHome(string provider) => provider == "claude" ? session.Current.ClaudeHome : session.Current.DeepseekHome;
    private bool CanEditHome(string provider) => !sourceClosed && !providerConnectionClosed && !busy && !session.RequiresRestart &&
        activePane == provider && homeProvider == provider && engine is { IsConnectionClosed: false } && providerHomeField?.IsVisible == true &&
        engine.LatestSnapshot?.Modules?.Any(value => value.Provider == provider && value.Enabled) == true;
    private FrameworkElement ProviderHomeEditor(string provider)
    {
        homeProvider = provider;
        var body = new StackPanel { Margin = new Thickness(14, 0, 14, 0) };
        body.Children.Add(Hairline(0, 0));
        var locations = Disclosure(ui.Text("provider.custom_locations"), body, SavedHome(provider).Length > 0, "settings." + provider + ".locations");
        providerHomeLocations = locations;
        string label = ui.Text(provider == "claude" ? "provider.claude_home" : "deepseek.home");
        // The default folder is the prompt, as the Mac shows ~/.claude.
        var field = new TextBox { Style = (Style)FindResource("SettingsPathInput"), Tag = provider == "claude" ? @"~\.claude" : label, MaxLength = 32768, VerticalContentAlignment = VerticalAlignment.Center };
        providerHomeField = field; Identify(field, "settings." + provider + ".home", label); editors.Add(field);
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitProviderHome(provider, field); } };
        field.LostKeyboardFocus += async (_, _) => { if (!synchronizing && !composing) await CommitProviderHome(provider, field); };
        var choose = new Button { Content = ui.Text("common.choose"), Margin = new Thickness(8,0,0,0) };
        providerHomeChoose = choose;
        Identify(choose, "settings." + provider + ".choose_home", label); editors.Add(choose);
        choose.Click += async (_, _) =>
        {
            if (!CanEditHome(provider) || !ReferenceEquals(providerHomeField, field)) return;
            var dialog = new OpenFolderDialog { Title = label };
            if (dialog.ShowDialog(this) == true && CanEditHome(provider)) { field.Text = dialog.FolderName; await CommitProviderHome(provider, field); }
        };
        body.Children.Add(LocationRow(label, field, choose));
        var hint = Detail(ui.Text("windows.settings.default_location")); hint.Margin = new Thickness(0, 0, 0, 10); body.Children.Add(hint);
        providerHomeIssue = SourceIssue("settings." + provider + ".home.issue"); body.Children.Add(providerHomeIssue);
        return locations;
    }
    /// A folder under the user's profile written from ~, as the Mac abbreviates its home folder.
    private static string ShortHome(string path)
    {
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return profile.Length > 0 && path.StartsWith(profile, StringComparison.OrdinalIgnoreCase) ? "~" + path[profile.Length..] : path;
    }
    private void RefreshProviderHome()
    {
        if (homeProvider == null || providerHomeField == null) return;
        string saved = SavedHome(homeProvider);
        bool enabled = !sourceClosed && !providerConnectionClosed && !busy && !session.RequiresRestart && engine is { IsConnectionClosed: false } &&
            engine.LatestSnapshot?.Modules?.Any(value => value.Provider == homeProvider && value.Enabled) == true;
        providerHomeField.IsEnabled = enabled; if (providerHomeChoose != null) providerHomeChoose.IsEnabled = enabled;
        if (homeSaved != saved) { homeSaved = saved; providerHomeField.Text = saved; SetSourceIssue(providerHomeIssue, null); }
        // DeepSeek's summary reports its state (RefreshDeepSeek sets it); Claude's shows the folder in use, home shortened to ~.
        if (providerHomeLocations != null && homeProvider == "claude") providerHomeLocations.Tag = saved.Length > 0 ? ui.Text("main.location.custom") : ShortHome(providerHomeField.ToolTip as string ?? "");
        string key = homeProvider + "\0" + saved;
        if (homeInspectionKey != key) homeInspection = InspectProviderHome(homeProvider, saved, homePaneRevision);
    }
    private async Task InspectProviderHome(string provider, string saved, long pane)
    {
        if (sourceClosed || engine == null) return;
        homeInspectionKey = provider + "\0" + saved;
        try
        {
            await sourceReady;
            if (sourceClosed || pane != homePaneRevision) return;
            var report = await engine.QueryAsync<ProviderHomeReport>("inspectProviderHome", new { provider, sourceHome = saved });
            if (sourceClosed || pane != homePaneRevision || SavedHome(provider) != saved || providerHomeField == null) return;
            providerHomeField.ToolTip = report.EffectiveHome;
            if (providerHomeLocations != null && saved.Length == 0 && provider == "claude") providerHomeLocations.Tag = ShortHome(report.EffectiveHome);
            if (providerHomeField.Text == saved && saved.Length > 0 && report.Issue != null) SetSourceIssue(providerHomeIssue, report.Issue);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        { if (!sourceClosed && pane == homePaneRevision) SetSourceIssue(providerHomeIssue, ui.Text("windows.settings.inspect_failed")); }
    }
    private async Task CommitProviderHome(string provider, TextBox field)
    {
        if (!CanEditHome(provider) || !ReferenceEquals(providerHomeField,field)) return;
        string value = field.Text, saved = SavedHome(provider);
        if (value == saved) { SetSourceIssue(providerHomeIssue,null); return; }
        if (homePending == value) return;
        if (Encoding.UTF8.GetByteCount(value) > 32768 || value.Any(char.IsControl)) { SetSourceIssue(providerHomeIssue,ui.Text("windows.settings.invalid_path")); return; }
        long pane = homePaneRevision, revision = ++homeFieldRevision; homePending = value; ClearIssue(); SetSourceIssue(providerHomeIssue, null);
        try
        {
            await sourceReady;
            if (!CanEditHome(provider) || pane != homePaneRevision || revision != homeFieldRevision || field.Text != value || SavedHome(provider) != saved) return;
            var report = await engine!.QueryAsync<ProviderHomeReport>("inspectProviderHome", new { provider, sourceHome = value });
            if (!CanEditHome(provider) || pane != homePaneRevision || revision != homeFieldRevision || field.Text != value || SavedHome(provider) != saved) return;
            SetSourceIssue(providerHomeIssue,report.Issue); if (report.Issue != null) return;
            var result = await Change(p => provider == "claude" ? p with { ClaudeHome = report.Home } : p with { DeepseekHome = report.Home });
            if (sourceClosed || pane != homePaneRevision) return;
            field.Text = result == PreferencesApplyResult.Applied ? report.Home : saved;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        { if (!sourceClosed && pane == homePaneRevision && revision == homeFieldRevision) SetSourceIssue(providerHomeIssue,ui.Text("windows.settings.inspect_failed")); }
        finally { if (pane == homePaneRevision && revision == homeFieldRevision) homePending = null; }
    }
}
