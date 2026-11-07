using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private PasswordBox? deepseekKeyInput;
    private Button? deepseekKeySave, deepseekKeyRemove, deepseekAccountOptions;
    private TextBlock? deepseekConnectionTitle, deepseekDetectedSource, deepseekKeyIssue;
    private StackPanel? deepseekKeyEditor;
    private ContextMenu? deepseekSourceMenu;
    private Border? deepseekConnectionSeparator, deepseekEditorSeparator;
    private MenuItem? deepseekSwitchAccount, deepseekSignOut;
    private Separator? deepseekWebMenuSeparator;
    private readonly Dictionary<string, MenuItem> deepseekSources = new();
    private bool deepseekConnectionBusy;
    private int deepseekConnectionRevision;
    private string? deepseekConnectionContext;
    private bool DeepSeekOfflineDemo => demo && (webConnection == null || webConnection.IsOfflineDemo);
    private string DeepSeekKeyHelp => ui.Text(demo ? "windows.deepseek.demo_key_help" : "windows.deepseek.key_help");
    private string DeepSeekWebHelp => ui.Text(DeepSeekOfflineDemo ? "windows.deepseek.demo_web_help" : "windows.deepseek.runtime_required");

    private void ClearDeepSeekConnection()
    {
        deepseekConnectionRevision++; deepseekConnectionBusy = false; deepseekConnectionContext = null;
        deepseekKeyInput?.Clear(); if (deepseekSourceMenu != null) deepseekSourceMenu.IsOpen = false;
        deepseekKeyInput = null; deepseekKeySave = deepseekKeyRemove = deepseekAccountOptions = null;
        deepseekConnectionTitle = deepseekDetectedSource = deepseekKeyIssue = null; deepseekKeyEditor = null;
        deepseekSourceMenu = null; deepseekSources.Clear();
        deepseekConnectionSeparator = deepseekEditorSeparator = null;
        deepseekSwitchAccount = deepseekSignOut = null; deepseekWebMenuSeparator = null;
    }
    private StackPanel BuildDeepSeekConnection()
    {
        deepseekConnectionTitle = Label(ui.Text("deepseek.platform_account"));
        deepseekSignIn = new Button { Content = ui.Text("deepseek.sign_in"), IsEnabled = false, Padding = new Thickness(12, 3, 12, 3) };
        Identify(deepseekSignIn, "settings.deepseek.sign_in", ui.Text("deepseek.sign_in")); editors.Add(deepseekSignIn);
        var actionButton = deepseekSignIn;
        actionButton.Click += async (_, _) =>
        {
            if (!ReferenceEquals(deepseekSignIn, actionButton) || !actionButton.IsVisible || !actionButton.IsEnabled) return;
            if (engine?.LatestSnapshot?.DeepseekConnection?.Reading.Action == "signIn") await ConnectDeepSeekWeb();
            else await RunDeepSeekConnection("retryDeepSeekBalance");
        };
        deepseekConnection = Label(""); deepseekConnection.Margin = new Thickness(0, 0, 8, 0); deepseekConnection.VerticalAlignment = VerticalAlignment.Center;
        var connection = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var dot = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, 8, 0) };
        deepseekConnectionDot = dot; connection.Children.Add(dot); connection.Children.Add(deepseekConnection); connection.Children.Add(deepseekSignIn);
        var icon = new IconGlyph { Symbol = "ellipsis.circle", Width = 14, Height = 14 }; icon.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        deepseekAccountOptions = new Button { Style = (Style)FindResource("DeepSeekInfoButton"), Width = 16, Height = 16,
            Margin = new Thickness(8, 0, 4, 0), Content = icon };
        Identify(deepseekAccountOptions, "settings.deepseek.account_options", ui.Text("claude.account.options")); editors.Add(deepseekAccountOptions);
        connection.Children.Add(deepseekAccountOptions);
        deepseekSourceMenu = new ContextMenu { Style = (Style)FindResource("SettingsConnectionMenu"), Language = Language,
            Placement = PlacementMode.Custom, CustomPopupPlacementCallback = (popup, target, _) => [
                new(new Point(target.Width - popup.Width, target.Height), PopupPrimaryAxis.Vertical),
                new(new Point(target.Width - popup.Width, -popup.Height), PopupPrimaryAxis.Vertical)] };
        deepseekSourceMenu.Resources.MergedDictionaries.Add(Resources);
        deepseekSourceMenu.Items.Add(new MenuItem { Header = ui.Text("deepseek.balance_source"), IsEnabled = false, Style = (Style)FindResource("SettingsConnectionMenuItem") });
        foreach (var choice in new[] { ("automatic", "deepseek.source.automatic"), ("web", "deepseek.source.web_short"), ("apiKey", "deepseek.source.api_short") })
        {
            var item = new MenuItem { Header = ui.Text(choice.Item2), IsCheckable = true, Tag = choice.Item1, Style = (Style)FindResource("SettingsConnectionMenuItem") };
            Identify(item, "settings.deepseek.source." + choice.Item1, ui.Text(choice.Item2)); deepseekSources[choice.Item1] = item;
            string value = choice.Item1;
            item.Click += async (_, _) =>
            {
                // WPF closes the popup before dispatching MenuItem.Click.
                // The current item identity and pane state reject detached controls.
                if (!CanUseDeepSeekConnection() || !item.IsEnabled ||
                    !deepseekSources.TryGetValue(value, out var current) || !ReferenceEquals(current, item)) return;
                await Change(p => p with { DeepSeekBalanceSource = value });
            };
            deepseekSourceMenu.Items.Add(item);
        }
        deepseekWebMenuSeparator = new Separator(); deepseekSourceMenu.Items.Add(deepseekWebMenuSeparator);
        deepseekSwitchAccount = new MenuItem { Header = ui.Text("claude.account.switch"), Style = (Style)FindResource("SettingsConnectionMenuItem") };
        deepseekSignOut = new MenuItem { Header = ui.Text("deepseek.sign_out"), Style = (Style)FindResource("SettingsConnectionMenuItem") };
        Identify(deepseekSwitchAccount, "settings.deepseek.account.switch", ui.Text("claude.account.switch"));
        Identify(deepseekSignOut, "settings.deepseek.account.sign_out", ui.Text("deepseek.sign_out"));
        var switchAccount = deepseekSwitchAccount; var signOut = deepseekSignOut;
        switchAccount.Click += async (_, _) => { if (ReferenceEquals(deepseekSwitchAccount, switchAccount) && CanUseDeepSeekConnection() && switchAccount.IsEnabled) await ConnectDeepSeekWeb(); };
        signOut.Click += async (_, _) => { if (ReferenceEquals(deepseekSignOut, signOut) && CanUseDeepSeekConnection() && signOut.IsEnabled) await RunDeepSeekConnection("disconnectDeepSeek"); };
        deepseekSourceMenu.Items.Add(deepseekSwitchAccount); deepseekSourceMenu.Items.Add(deepseekSignOut);
        deepseekAccountOptions.ContextMenu = deepseekSourceMenu;
        var optionsButton = deepseekAccountOptions;
        deepseekAccountOptions.Click += (_, _) =>
        {
            if (ReferenceEquals(deepseekAccountOptions, optionsButton) && CanUseDeepSeekConnection() && optionsButton.IsVisible && optionsButton.IsEnabled)
            { deepseekSourceMenu.PlacementTarget = deepseekAccountOptions; deepseekSourceMenu.IsOpen = true; }
        };
        Border Line() { var line = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return line; }
        var body = new StackPanel(); body.Children.Add(Row(deepseekConnectionTitle, connection, 44));
        deepseekConnectionSeparator = Line(); body.Children.Add(deepseekConnectionSeparator);
        deepseekDetectedSource = DeepSeekCaption(""); body.Children.Add(deepseekDetectedSource);
        var accountHelp = DeepSeekCaption(DeepSeekWebHelp);
        if (!DeepSeekOfflineDemo)
        {
            var download = new Hyperlink(new Run(" " + ui.Text("windows.deepseek.runtime_download")));
            download.Click += (_, _) =>
            {
                try { Process.Start(new ProcessStartInfo("https://developer.microsoft.com/en-us/microsoft-edge/webview2/#download-section") { UseShellExecute = true }); }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { ShowIssue("windows.connection.refresh_failed"); }
            };
            accountHelp.Inlines.Add(download);
        }
        deepseekAccountHelp = accountHelp; body.Children.Add(deepseekAccountHelp);
        deepseekKeyEditor = new StackPanel();
        deepseekEditorSeparator = Line(); deepseekKeyEditor.Children.Add(deepseekEditorSeparator);
        var keys = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        // Keep one invalid extra character so paste cannot truncate an oversized
        // key into an accepted 256-byte credential and replace a saved key.
        deepseekKeyInput = new PasswordBox { MaxLength = 257, Width = 120, HorizontalContentAlignment = HorizontalAlignment.Right,
            Style = (Style)FindResource("SettingsSecretInput"), VerticalAlignment = VerticalAlignment.Center };
        Identify(deepseekKeyInput, "settings.deepseek.key.input", ui.Text("deepseek.paste_key")); editors.Add(deepseekKeyInput);
        var input = new Grid(); input.Children.Add(deepseekKeyInput);
        var prompt = new TextBlock { Text = "sk-…", Margin = new Thickness(0, 0, 0, 2), HorizontalAlignment = HorizontalAlignment.Right,
            IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center };
        prompt.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); input.Children.Add(prompt); keys.Children.Add(input);
        var keyInput = deepseekKeyInput;
        keyInput.PasswordChanged += (_, _) => { if (!ReferenceEquals(deepseekKeyInput, keyInput)) return; using var value = keyInput.SecurePassword; prompt.Visibility = value.Length == 0 ? Visibility.Visible : Visibility.Collapsed; RefreshDeepSeekKeyButtons(); };
        keyInput.KeyDown += async (_, e) => { if (e.Key == Key.Enter && ReferenceEquals(deepseekKeyInput, keyInput) && keyInput.IsVisible && keyInput.IsEnabled) { e.Handled = true; await SaveDeepSeekKey(); } };
        deepseekKeySave = new Button { Content = ui.Text("common.save"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        deepseekKeyRemove = new Button { Content = ui.Text("deepseek.remove_key"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Identify(deepseekKeySave, "settings.deepseek.key.save", ui.Text("common.save")); Identify(deepseekKeyRemove, "settings.deepseek.key.remove", ui.Text("deepseek.remove_key"));
        editors.Add(deepseekKeySave); editors.Add(deepseekKeyRemove);
        keys.Children.Add(deepseekKeySave); keys.Children.Add(deepseekKeyRemove);
        var saveButton = deepseekKeySave; var removeButton = deepseekKeyRemove;
        saveButton.Click += async (_, _) => { if (ReferenceEquals(deepseekKeySave, saveButton) && saveButton.IsVisible && saveButton.IsEnabled) await SaveDeepSeekKey(); };
        removeButton.Click += async (_, _) => { if (ReferenceEquals(deepseekKeyRemove, removeButton) && removeButton.IsVisible && removeButton.IsEnabled) await RunDeepSeekConnection("removeDeepSeekKey"); };
        var keyLabel = Label(ui.Text("deepseek.paste_key")); Identify(keyLabel, "settings.deepseek.key.label", ui.Text("deepseek.paste_key"));
        deepseekKeyEditor.Children.Add(Row(keyLabel, keys, 44)); deepseekKeyEditor.Children.Add(Line());
        deepseekKeyIssue = DeepSeekCaption(DeepSeekKeyHelp); deepseekKeyIssue.Margin = new Thickness(10, 10, 10, 12);
        Identify(deepseekKeyIssue, "settings.deepseek.key.issue", ""); deepseekKeyEditor.Children.Add(deepseekKeyIssue);
        body.Children.Add(deepseekKeyEditor); return body;
    }
    private bool CanUseDeepSeekConnection() => !sourceClosed && activePane == "deepseek" && !busy && !deepseekConnectionBusy && !session.RequiresRestart &&
        engine != null && !engine.IsConnectionClosed && !providerConnectionClosed && deepseekSections?.IsVisible == true && engine.LatestSnapshot?.DeepseekConnection != null;
    private async Task SaveDeepSeekKey()
    {
        if (!CanUseDeepSeekConnection() || deepseekKeyInput?.IsVisible != true || deepseekKeySave?.IsEnabled != true) return;
        string key = deepseekKeyInput.Password; deepseekKeyInput.Clear();
        await RunDeepSeekConnection("saveDeepSeekKey", key);
    }
    private async Task ConnectDeepSeekWeb()
    {
        if (!CanUseDeepSeekConnection() || webConnection?.Available != true || engine?.LatestSnapshot?.DeepseekConnection is not DeepSeekConnection state ||
            state.Mode == "apiKey") return;
        int revision = deepseekConnectionRevision;
        try { await webConnection.ConnectAsync(state.Context); }
        catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
        {
            if (!sourceClosed && revision == deepseekConnectionRevision && engine.LatestSnapshot?.DeepseekConnection?.Context == state.Context)
                ShowIssue("windows.connection.refresh_failed");
        }
    }
    private async Task RunDeepSeekConnection(string method, string? key = null)
    {
        if (!CanUseDeepSeekConnection() || engine?.LatestSnapshot?.DeepseekConnection is not DeepSeekConnection state) return;
        int revision = deepseekConnectionRevision; deepseekConnectionBusy = true; RefreshDeepSeekKeyButtons();
        try
        {
            await sourceReady;
            if (sourceClosed || activePane != "deepseek" || revision != deepseekConnectionRevision ||
                engine.LatestSnapshot?.DeepseekConnection?.Context != state.Context) return;
            if (deepseekKeyIssue != null) { deepseekKeyIssue.Text = DeepSeekKeyHelp; deepseekKeyIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); }
            if (webConnection != null && method is "removeDeepSeekKey" or "disconnectDeepSeek") await webConnection.DisconnectAsync(state.Context);
            else await engine.SendAsync(method, new { balanceContext = state.Context, deepseekKey = key });
        }
        catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
        {
            if (!sourceClosed && revision == deepseekConnectionRevision && deepseekKeyIssue != null)
            {
                if (method != "saveDeepSeekKey" && deepseekSections?.IsVisible == true) ShowIssue("windows.connection.refresh_failed");
                deepseekKeyIssue.Text = ui.Text(error is EngineCommandException command && command.Code == "invalidCredential" ? "deepseek.key_invalid" : "windows.connection.refresh_failed");
                deepseekKeyIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
            }
        }
        finally { if (!sourceClosed && revision == deepseekConnectionRevision) { deepseekConnectionBusy = false; RefreshValues(); } }
    }
    private void RefreshDeepSeekKeyButtons()
    {
        if (deepseekKeyInput == null) return;
        bool available = CanUseDeepSeekConnection(); using var password = deepseekKeyInput.SecurePassword;
        deepseekKeyInput.IsEnabled = available; deepseekKeySave!.IsEnabled = available && password.Length > 0;
        deepseekKeyRemove!.IsEnabled = available; deepseekAccountOptions!.IsEnabled = available;
        var state = engine?.LatestSnapshot?.DeepseekConnection;
        deepseekSignIn!.IsEnabled = available && state != null &&
            (state.Reading.Action == "refresh" && !state.Refreshing || state.Reading.Action == "signIn" && state.WebAvailable && webConnection?.Available == true);
    }
    private void RefreshDeepSeekConnection(bool connected, EngineWallet? wallet)
    {
        if (deepseekConnectionTitle == null) return;
        var state = connected ? engine?.LatestSnapshot?.DeepseekConnection : null;
        if (state == null)
        {
            deepseekConnection!.Text = connected ? wallet?.Settings?.ConnectionText ?? "" : ui.Text("windows.connection.closed");
            deepseekConnection.SetResourceReference(TextBlock.ForegroundProperty, wallet?.Balance == null ? "SettingsWarning" : "SettingsSecondary");
            deepseekSignIn!.Visibility = wallet?.Balance == null ? Visibility.Visible : Visibility.Collapsed;
            deepseekAccountHelp!.Visibility = wallet?.Balance == null ? Visibility.Visible : Visibility.Collapsed;
            deepseekKeyEditor!.Visibility = deepseekDetectedSource!.Visibility = Visibility.Collapsed;
            deepseekConnectionDot!.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, wallet?.Balance == null ? "SettingsWarning" : "SettingsSuccess");
        }
        else
        {
            var value = state.Reading;
            if (deepseekConnectionContext != state.Context)
            {
                deepseekConnectionContext = state.Context; deepseekKeyInput!.Clear();
                deepseekKeyIssue!.Text = DeepSeekKeyHelp; deepseekKeyIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            }
            deepseekConnectionTitle.Text = value.Title; deepseekConnection!.Text = value.Text;
            deepseekConnection.SetResourceReference(TextBlock.ForegroundProperty, value.Color == "orange" ? "SettingsWarning" : "SettingsSecondary");
            deepseekConnectionDot!.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, value.Color == "green" ? "SettingsSuccess" : value.Color == "orange" ? "SettingsWarning" : "SettingsSecondary");
            deepseekSignIn!.Content = value.ActionLabel ?? ui.Text("deepseek.sign_in"); AutomationProperties.SetName(deepseekSignIn, (string)deepseekSignIn.Content);
            deepseekSignIn.Visibility = value.Action == null ? Visibility.Collapsed : Visibility.Visible;
            deepseekSignIn.ToolTip = value.Action == "signIn" && (!state.WebAvailable || webConnection?.Available != true) ? DeepSeekWebHelp : null;
            deepseekAccountHelp!.Visibility = state.Mode != "apiKey" && (!state.WebAvailable || webConnection?.Available != true) && !value.Connected ? Visibility.Visible : Visibility.Collapsed;
            deepseekDetectedSource!.Text = value.DetectedText; deepseekDetectedSource.Visibility = value.ShowDetection ? Visibility.Visible : Visibility.Collapsed;
            deepseekKeyEditor!.Visibility = value.KeyEditor ? Visibility.Visible : Visibility.Collapsed;
            deepseekKeyRemove!.Visibility = state.HasKey ? Visibility.Visible : Visibility.Collapsed;
            if (!value.KeyEditor) deepseekKeyInput!.Clear();
        }
        foreach (var choice in deepseekSources) { choice.Value.IsChecked = choice.Key == session.Current.DeepSeekBalanceSource; choice.Value.IsEnabled = CanUseDeepSeekConnection(); }
        deepseekConnectionSeparator!.Visibility = deepseekDetectedSource!.Visibility == Visibility.Visible || deepseekKeyEditor!.Visibility == Visibility.Visible ||
            deepseekAccountHelp!.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        deepseekEditorSeparator!.Visibility = deepseekDetectedSource.Visibility == Visibility.Visible || deepseekAccountHelp.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        bool webMenu = state is { Reading.Connected: true } && state.Mode != "apiKey";
        deepseekWebMenuSeparator!.Visibility = deepseekSwitchAccount!.Visibility = deepseekSignOut!.Visibility = webMenu ? Visibility.Visible : Visibility.Collapsed;
        deepseekSwitchAccount.IsEnabled = CanUseDeepSeekConnection() && webConnection?.Available == true;
        deepseekSignOut.IsEnabled = CanUseDeepSeekConnection() && webConnection != null;
        RefreshDeepSeekKeyButtons();
    }
}
