using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private TextBlock? claudeAccountState, claudeAccountHelp, claudeHistoryTitle;
    private Button? claudeSignIn, claudeOptions, claudeRuntimeDownload;
    private QuotaHistoryView? claudeHistoryView;
    private long claudeAccountRevision;
    private bool claudeAccountBusy;
    private void ClearClaudeConnection()
    {
        claudeAccountRevision++; claudeAccountBusy = false;
        claudeAccountState = claudeAccountHelp = claudeHistoryTitle = null;
        claudeSignIn = claudeOptions = claudeRuntimeDownload = null; claudeHistoryView = null;
    }
    private FrameworkElement BuildClaudeConnection()
    {
        var content = new StackPanel(); var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        claudeAccountState = Detail(""); claudeAccountState.Margin = new Thickness(0, 0, 8, 0);
        Identify(claudeAccountState, "settings.claude.account_state", ""); trailing.Children.Add(claudeAccountState);
        claudeSignIn = new Button { Content = ui.Text("welcome.module.sign_in") };
        Identify(claudeSignIn, "settings.claude.sign_in", ui.Text("claude.quota.connect")); editors.Add(claudeSignIn); trailing.Children.Add(claudeSignIn);
        claudeSignIn.Click += async (_, _) =>
        {
            if (engine?.LatestSnapshot?.ClaudeConnection is not { } state) return;
            if (state.State == "workspaceNeeded") await OpenClaudeAccountMenu(true);
            else await ChangeClaudeAccount(state.Context, "signIn");
        };
        claudeOptions = new Button { Content = "•••", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 0, 8, 0) };
        Identify(claudeOptions, "settings.claude.account_options", ui.Text("claude.account.options")); editors.Add(claudeOptions); trailing.Children.Add(claudeOptions);
        claudeOptions.Click += async (_, _) => await OpenClaudeAccountMenu(false);
        content.Children.Add(Row(Label(ui.Text("claude.account")), trailing));
        claudeAccountHelp = Detail(""); claudeAccountHelp.Margin = new Thickness(14, -4, 14, 10); content.Children.Add(claudeAccountHelp);
        claudeRuntimeDownload = new Button { Content = ui.Text("windows.deepseek.runtime_download"), Style = (Style)FindResource("SettingsLink"),
            HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(14, 0, 14, 10) };
        Identify(claudeRuntimeDownload, "settings.claude.runtime_download", ui.Text("windows.deepseek.runtime_download"));
        claudeRuntimeDownload.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("https://developer.microsoft.com/en-us/microsoft-edge/webview2/#download-section") { UseShellExecute = true }); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { ShowIssue("windows.connection.refresh_failed"); }
        };
        content.Children.Add(claudeRuntimeDownload); return content;
    }
    private void BuildClaudeHistory(StackPanel parent)
    {
        claudeHistoryTitle = Label("", 13, FontWeights.SemiBold); claudeHistoryTitle.Margin = new Thickness(10, 20, 0, 8); parent.Children.Add(claudeHistoryTitle);
        claudeHistoryView = new QuotaHistoryView(ui, PacerPalette.Claude, async () =>
        { if (!sourceClosed && engine != null) await engine.SendAsync("retryQuota", new { provider = "claude" }); });
        parent.Children.Add(Card(claudeHistoryView));
    }
    private void RefreshClaudeConnection(bool connected)
    {
        if (claudeSignIn == null) return;
        var state = engine?.LatestSnapshot?.ClaudeConnection;
        claudeAccountState!.Text = ui.Text(state?.State switch {
            "signedIn" => "claude.account.signed_in", "signedOut" => "claude.account.signed_out", "workspaceNeeded" => "claude.account.workspace_needed",
            "checking" => "claude.account.checking", _ => "claude.account.unavailable" });
        // Sign-in reads as a status; amber only when Claude needs the user.
        claudeAccountState.SetResourceReference(TextBlock.ForegroundProperty, state?.State is "signedOut" or "workspaceNeeded" ? "SettingsWarning" : "SettingsSecondary");
        bool offline = claudeConnection?.IsOfflineDemo ?? demo;
        bool available = connected && !offline && claudeConnection?.Available == true && state != null;
        claudeSignIn.IsEnabled = claudeOptions!.IsEnabled = available && !busy && !claudeAccountBusy && !session.RequiresRestart;
        claudeSignIn.Visibility = state?.State == "signedIn" ? Visibility.Collapsed : Visibility.Visible;
        claudeSignIn.Content = ui.Text(state?.State == "workspaceNeeded" ? "claude.login.organization_title" : "welcome.module.sign_in");
        string help = offline ? ui.Text("windows.claude.demo_web_help") : claudeConnection is { Available: false } ? ui.Text("windows.claude.runtime_required") :
            claudeConnection?.LastFailure is string failure ? ui.Text(failure) : state?.Message ?? "";
        claudeAccountHelp!.Text = help; claudeAccountHelp.Visibility = help.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        claudeRuntimeDownload!.Visibility = !offline && claudeConnection is { Available: false } ? Visibility.Visible : Visibility.Collapsed;
        var history = engine?.LatestSnapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == "claude")?.History;
        if (claudeHistoryTitle != null) { claudeHistoryTitle.Text = history?.Title ?? ""; claudeHistoryTitle.Visibility = history?.Title == null ? Visibility.Collapsed : Visibility.Visible; }
        if (!connected) claudeHistoryView?.ShowUnavailable(ui.Text("windows.connection.closed")); else claudeHistoryView?.Update(history);
        claudeHistoryView?.SetInteractionEnabled(connected && !busy && !claudeAccountBusy && !session.RequiresRestart);
    }
    private bool CurrentClaudeAccount(string context) => !sourceClosed && !providerConnectionClosed && activePane == "claude" &&
        claudeSections?.IsVisible == true && claudeEnabled?.IsChecked == true && !busy && !claudeAccountBusy && !session.RequiresRestart &&
        claudeConnection?.Available == true && engine?.LatestSnapshot?.ClaudeConnection?.Context == context;
    private async Task RunClaudeAccountAction(string context, Func<Task<bool>> action)
    {
        if (!CurrentClaudeAccount(context)) return;
        long revision = claudeAccountRevision; claudeAccountBusy = true; ClearIssue(); RefreshClaudeConnection(true);
        try { if (!await action() && !sourceClosed && revision == claudeAccountRevision && claudeConnection?.LastFailure is string error) ShowIssue(error); }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { if (!sourceClosed && revision == claudeAccountRevision) ShowIssue("windows.claude.connection_failed"); }
        finally { if (revision == claudeAccountRevision && !sourceClosed) { claudeAccountBusy = false; RefreshValues(); } }
    }
    private async Task OpenClaudeAccountMenu(bool chooseOnly)
    {
        if (engine?.LatestSnapshot?.ClaudeConnection is not { } state || !CurrentClaudeAccount(state.Context)) return;
        long revision = claudeAccountRevision;
        try
        {
            await sourceReady; var report = await engine.QueryAsync<ClaudeAccountReport>("inspectClaudeAccount");
            if (revision != claudeAccountRevision || report.Context != state.Context || !CurrentClaudeAccount(report.Context)) return;
            if (chooseOnly) { await ChooseClaudeOrganization(report, revision); return; }
            var menu = new ContextMenu { PlacementTarget = claudeOptions, FontFamily = PacerFonts.Interface };
            var refresh = new MenuItem { Header = ui.Text("common.refresh") }; Identify(refresh, "settings.claude.refresh", ui.Text("common.refresh"));
            refresh.Click += async (_, _) => await RunClaudeAccountAction(report.Context, async () => { await engine.SendAsync("retryQuota", new { provider = "claude" }); return true; }); menu.Items.Add(refresh);
            var choose = new MenuItem { Header = ui.Text("claude.login.organization_title"), IsEnabled = report.Organizations.Count > 0 };
            Identify(choose, "settings.claude.choose_organization", ui.Text("claude.login.organization_title"));
            choose.Click += async (_, _) => await ChooseClaudeOrganization(report, revision); menu.Items.Add(choose);
            var change = new MenuItem { Header = ui.Text("claude.account.switch") }; Identify(change, "settings.claude.switch_account", ui.Text("claude.account.switch"));
            change.Click += async (_, _) => await ChangeClaudeAccount(report.Context, "switch"); menu.Items.Add(change);
            var signOut = new MenuItem { Header = ui.Text("windows.claude.sign_out") }; Identify(signOut, "settings.claude.sign_out", ui.Text("windows.claude.sign_out"));
            signOut.Click += async (_, _) => await ChangeClaudeAccount(report.Context, "signOut"); menu.Items.Add(signOut);
            claudeOptions!.ContextMenu = menu; menu.IsOpen = true;
        }
        catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException)
        { if (!sourceClosed && revision == claudeAccountRevision) ShowIssue("windows.claude.connection_failed"); }
    }
    private async Task ChangeClaudeAccount(string context, string action)
    {
        if (!CurrentClaudeAccount(context)) return;
        long revision = claudeAccountRevision;
        if (session.Current.ClaudeOrganization.Length > 0)
        {
            if (await Change(p => p with { ClaudeOrganization = "" }) != PreferencesApplyResult.Applied || sourceClosed || revision != claudeAccountRevision) return;
            context = engine?.LatestSnapshot?.ClaudeConnection?.Context ?? "";
        }
        if (!CurrentClaudeAccount(context)) return;
        await RunClaudeAccountAction(context, () => action == "signOut" ? claudeConnection!.DisconnectAsync(context) :
            claudeConnection!.ConnectAsync(context, switchAccount: action == "switch"));
    }
    private async Task ChooseClaudeOrganization(ClaudeAccountReport report, long revision)
    {
        if (report.Organizations.Count == 0 || revision != claudeAccountRevision || !CurrentClaudeAccount(report.Context)) return;
        var dialog = new Window { Owner = this, Title = ui.Text("claude.login.organization_title"), WindowStartupLocation = WindowStartupLocation.CenterOwner,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize, FontFamily = PacerFonts.Interface, Language = Language };
        WindowRendering.Prepare(dialog);
        dialog.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SettingsPalette.Apply(dialog.Resources, darkOverride ?? IsSystemDark(), true); dialog.SetResourceReference(BackgroundProperty, "SettingsBackground");
        var content = new StackPanel { Width = 380, Margin = new Thickness(20) }; dialog.Content = content;
        var instructions = Detail(ui.Text("claude.login.organization_instructions")); instructions.Margin = new Thickness(0, 0, 0, 14); content.Children.Add(instructions);
        var picker = new ComboBox { Margin = new Thickness(0, 0, 0, 18) }; Identify(picker, "claude.organization.picker", ui.Text("claude.login.organization_title"));
        picker.Items.Add(new ComboBoxItem { Content = ui.Text("claude.login.organization_placeholder"), IsSelected = true });
        for (int i = 0; i < Math.Min(64, report.Organizations.Count); i++)
        {
            var organization = report.Organizations[i];
            string label = organization.Label ?? organization.Name ?? "—";
            picker.Items.Add(new ComboBoxItem { Content = label, Tag = organization.ID });
        }
        content.Children.Add(picker); var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = ui.Text("common.cancel"), MinWidth = 72, Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        var proceed = new Button { Content = ui.Text("claude.login.continue"), MinWidth = 80, IsDefault = true, IsEnabled = false };
        Identify(proceed, "claude.organization.continue", ui.Text("claude.login.continue")); actions.Children.Add(cancel); actions.Children.Add(proceed); content.Children.Add(actions);
        picker.SelectionChanged += (_, _) => proceed.IsEnabled = picker.SelectedItem is ComboBoxItem { Tag: string };
        proceed.Click += (_, _) => dialog.DialogResult = true;
        if (dialog.ShowDialog() == true && picker.SelectedItem is ComboBoxItem { Tag: string selected } && revision == claudeAccountRevision && CurrentClaudeAccount(report.Context))
            await Change(p => p with { ClaudeOrganization = selected });
    }
}
