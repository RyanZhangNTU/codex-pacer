using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// Windows browser login composition: host, page, instructions and Continue.
internal class ProviderLoginWindow : Window
{
    private readonly UiText ui;
    private readonly ProviderWebDefinition provider;
    private readonly Task<CoreWebView2Environment> environment;
    private readonly Action<CoreWebView2>? fixture;
    private readonly bool? darkOverride;
    private readonly CancellationTokenSource lifetime;
    private readonly CancellationToken cancellation;
    private readonly TaskCompletionSource<bool> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly ProviderBrowserPage page;
    private readonly Dictionary<Window, ProviderBrowserPage> popups = new();
    private readonly TextBlock address = new() { FontSize = 12, FontWeight = FontWeights.Medium, Margin = new Thickness(18, 12, 18, 10) };
    private readonly TextBlock message = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button proceed = new() { MinWidth = 88, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private bool checking, closed;
    internal Task<bool> Completion => completion.Task;
    internal Task CheckCompletion { get; private set; } = Task.CompletedTask;
    internal Grid ClientContent { get; } = new();

    internal ProviderLoginWindow(UiText ui, Task<CoreWebView2Environment> environment, Action<CoreWebView2>? fixture, bool? darkOverride, CancellationToken lifetime, ProviderWebDefinition provider)
    {
        this.ui = ui; this.provider = provider; this.environment = environment; this.fixture = fixture; this.darkOverride = darkOverride;
        this.lifetime = CancellationTokenSource.CreateLinkedTokenSource(lifetime); cancellation = this.lifetime.Token;
        Title = ui.Text(provider.ID + ".login.title"); MinWidth = 420; MinHeight = 400; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SetResourceReference(BackgroundProperty, "SettingsBackground");
        address.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        address.Text = provider.Origin.IdnHost; message.Text = ui.Text("windows." + provider.ID + ".login.instructions"); proceed.Content = ui.Text("claude.login.continue");
        AutomationProperties.SetAutomationId(address, provider.ID + ".login.host"); AutomationProperties.SetAutomationId(message, provider.ID + ".login.instructions");
        AutomationProperties.SetAutomationId(proceed, provider.ID + ".login.continue"); AutomationProperties.SetName(proceed, (string)proceed.Content);
        ClientContent.RowDefinitions.Add(new() { Height = GridLength.Auto }); ClientContent.RowDefinitions.Add(new());
        ClientContent.RowDefinitions.Add(new() { Height = GridLength.Auto });
        ClientContent.Children.Add(address);
        page = new(this, provider, closeWindow: false); Grid.SetRow(page.View, 1); ClientContent.Children.Add(page.View);
        var footer = new Grid { Margin = new Thickness(18, 14, 18, 16) };
        footer.ColumnDefinitions.Add(new()); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        footer.Children.Add(message); Grid.SetColumn(proceed, 1); footer.Children.Add(proceed); Grid.SetRow(footer, 2); ClientContent.Children.Add(footer);
        Content = ClientContent; SetInitialContentSize(this, ClientContent, 760, 800);
        proceed.Click += async (_, _) => await (CheckCompletion = ContinueAsync());
        PreviewKeyDown += async (_, e) => { if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await (CheckCompletion = ContinueAsync()); } };
        Activated += (_, _) => RefreshTheme(); Deactivated += (_, _) => RefreshTheme();
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        Closed += (_, _) =>
        {
            if (closed) return; closed = true; this.lifetime.Cancel();
            foreach (var popup in popups.Keys.ToArray()) popup.Close(); popups.Clear();
            page.Dispose(); completion.TrySetResult(false); SystemEvents.UserPreferenceChanged -= PreferenceChanged; this.lifetime.Dispose();
        };
        RefreshTheme();
    }
    internal async Task StartAsync()
    {
        try
        {
            var runtime = await environment.WaitAsync(cancellation);
            await page.Initialize(runtime, cancellation); fixture?.Invoke(page.Core); Configure(page, this);
            RefreshBrowserTheme();
            await page.Navigate(new Uri(provider.Origin, provider.LoginPath), cancellation);
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
    }
    private async Task ContinueAsync()
    {
        if (closed || checking || !page.IsUsable || !provider.IsOrigin(page.Core.Source)) return;
        checking = true;
        try
        {
            bool signedIn;
            if (provider.ID == "claude") signedIn = await ClaudeWebCookies.ReadAsync(page.Core, cancellation) != null;
            else
            {
                var evidence = await page.Evaluate(DeepSeekWebScripts.Shared.SignedIn, cancellation);
                signedIn = evidence.ValueKind == JsonValueKind.String && evidence.GetString() is { Length: 64 } hash && hash.All(Uri.IsHexDigit);
            }
            if (!closed && signedIn) { completion.TrySetResult(true); Close(); }
            else if (!closed) message.Text = ui.Text("windows." + provider.ID + ".login.instructions");
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
        finally { checking = false; }
    }
    private void Configure(ProviderBrowserPage browser, Window window)
    {
        browser.Core.NavigationStarting += (_, e) => { if (!AllowedNavigation(e.Uri)) e.Cancel = true; };
        browser.Core.SourceChanged += (_, _) => { if (ReferenceEquals(browser, page) && browser.IsUsable) address.Text = Host(browser.Core.Source); };
        browser.Core.NavigationCompleted += (_, e) =>
        {
            if (ReferenceEquals(browser, page) && !e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                message.Text = ui.Text("claude.login.load_failed");
        };
        browser.Core.WindowCloseRequested += (_, _) => window.Close();
        browser.Core.ProcessFailed += (_, _) => { if (!closed && ReferenceEquals(browser, page)) message.Text = ui.Text("claude.login.load_failed"); };
        browser.Core.NewWindowRequested += async (_, e) => await OpenPopup(e);
    }
    private async Task OpenPopup(CoreWebView2NewWindowRequestedEventArgs request)
    {
        request.Handled = true;
        if (closed || popups.Count >= 4 || !AllowedNavigation(request.Uri)) return;
        var deferred = request.GetDeferral();
        Window? window = null;
        try
        {
            window = new Window { Title = Title, MinWidth = 420, MinHeight = 400, WindowStartupLocation = WindowStartupLocation.CenterScreen,
                Language = Language, FontFamily = FontFamily };
            var browser = new ProviderBrowserPage(window, provider, closeWindow: false);
            window.Content = browser.View; SetInitialContentSize(window, browser.View, 620, 740); popups[window] = browser;
            var child = window;
            window.Closed += (_, _) => { if (popups.Remove(child, out var removed)) removed.Dispose(); };
            window.Show(); await browser.Initialize(await environment.WaitAsync(cancellation), cancellation); fixture?.Invoke(browser.Core);
            if (closed) { window.Close(); return; }
            Configure(browser, window); request.NewWindow = browser.Core;
        }
        catch (Exception error) when (Recoverable(error)) { window?.Close(); if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
        finally
        {
            try { deferred.Dispose(); }
            catch (COMException error) when (closed || cancellation.IsCancellationRequested || error.HResult == unchecked((int)0x8000000E)) { }
        }
    }
    private void PreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.InvokeAsync(() => { if (!closed) RefreshTheme(); });
    private void RefreshTheme()
    {
        SettingsPalette.Apply(Resources, darkOverride ?? SettingsWindow.IsSystemDark(), IsActive);
        if (page.IsUsable) RefreshBrowserTheme();
    }
    private void RefreshBrowserTheme()
    {
        try
        {
            if (page.IsUsable) page.Core.Profile.PreferredColorScheme = darkOverride is bool dark ?
                dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light : CoreWebView2PreferredColorScheme.Auto;
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
    }
    private string Host(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.IdnHost) ? uri.IdnHost : provider.Origin.IdnHost;
    internal static bool AllowedNavigation(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == "about");
    internal static bool Recoverable(Exception error) => error is IOException or COMException or OperationCanceledException or InvalidOperationException or ArgumentException or
        UnauthorizedAccessException or WebView2RuntimeNotFoundException;
    private static void SetInitialContentSize(Window window, FrameworkElement content, double width, double height)
    {
        var available = SystemParameters.WorkArea;
        content.Width = Math.Min(width, Math.Max(420, available.Width - 80)); content.Height = Math.Min(height, Math.Max(400, available.Height - 100));
        window.SizeToContent = SizeToContent.WidthAndHeight;
        window.Loaded += (_, _) =>
        {
            double outerWidth = window.ActualWidth, outerHeight = window.ActualHeight;
            window.SizeToContent = SizeToContent.Manual; content.ClearValue(WidthProperty); content.ClearValue(HeightProperty);
            window.Width = outerWidth; window.Height = outerHeight;
        };
    }
}
