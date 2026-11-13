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
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// Owned-profile login with a fingerprint baseline, bounded checks and automatic completion.
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
    private readonly Button refresh = new() { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button later = new() { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private bool checking, closed, finishing, allowClose, baselineKnown, signedIn;
    private int autoCloseRevision;
    private string? baseline;
    private Func<CancellationToken, Task<string?>>? readProfileFingerprint;
    private readonly DispatcherTimer observer = new() { Interval = TimeSpan.FromSeconds(1) };
    internal bool NewSession { get; private set; }
    internal int SessionChecks { get; private set; }
    internal Task<bool> Completion => completion.Task;
    internal Task CheckCompletion { get; private set; } = Task.CompletedTask;
    internal Grid ClientContent { get; } = new();

    internal ProviderLoginWindow(UiText ui, Task<CoreWebView2Environment> environment, Action<CoreWebView2>? fixture, bool? darkOverride, CancellationToken lifetime, ProviderWebDefinition provider)
    {
        this.ui = ui; this.provider = provider; this.environment = environment; this.fixture = fixture; this.darkOverride = darkOverride;
        WindowRendering.Prepare(this);
        this.lifetime = CancellationTokenSource.CreateLinkedTokenSource(lifetime); cancellation = this.lifetime.Token;
        Title = ui.Text(provider.ID + ".login.title"); MinWidth = 420; MinHeight = 400; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SetResourceReference(BackgroundProperty, "SettingsBackground");
        address.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        address.Text = provider.Origin.IdnHost; message.Text = ui.Text("windows." + provider.ID + ".login.instructions");
        proceed.Content = ui.Text(provider.WatchSignIn ? "claude.login.continue" : "login.done");
        AutomationProperties.SetAutomationId(address, provider.ID + ".login.host"); AutomationProperties.SetAutomationId(message, provider.ID + ".login.instructions");
        AutomationProperties.SetAutomationId(proceed, provider.ID + ".login.continue"); AutomationProperties.SetName(proceed, (string)proceed.Content);
        refresh.Content = ui.Text("common.refresh"); later.Content = ui.Text("login.later");
        AutomationProperties.SetAutomationId(refresh, provider.ID + ".login.refresh"); AutomationProperties.SetAutomationId(later, provider.ID + ".login.later");
        ClientContent.RowDefinitions.Add(new() { Height = GridLength.Auto }); ClientContent.RowDefinitions.Add(new());
        ClientContent.RowDefinitions.Add(new() { Height = GridLength.Auto });
        ClientContent.Children.Add(address);
        page = new(this, provider, closeWindow: false); Grid.SetRow(page.View, 1); ClientContent.Children.Add(page.View);
        var footer = new Grid { Margin = new Thickness(18, 14, 18, 16) };
        footer.ColumnDefinitions.Add(new()); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var actions = new StackPanel { Orientation = Orientation.Horizontal }; actions.Children.Add(refresh); actions.Children.Add(later); actions.Children.Add(proceed);
        footer.Children.Add(message); Grid.SetColumn(actions, 1); footer.Children.Add(actions); Grid.SetRow(footer, 2); ClientContent.Children.Add(footer);
        Content = ClientContent; SetInitialContentSize(this, ClientContent, 760, 800);
        proceed.Click += async (_, _) => await (CheckCompletion = ContinueAsync());
        refresh.Click += (_, _) => { if (page.IsUsable) page.Core.Reload(); };
        later.Click += (_, _) => Close();
        observer.Tick += async (_, _) => await ObserveAsync();
        Closing += async (_, e) =>
        {
            if (allowClose || closed) return;
            e.Cancel = true;
            // Leave WPF's Closing stack before a completed probe or Abort calls Close again.
            await Dispatcher.Yield(DispatcherPriority.Background);
            if (closed) return;
            if (!baselineKnown || !provider.WatchSignIn) { Abort(); return; }
            await (CheckCompletion = FinishAsync(requiringSession: false));
        };
        PreviewKeyDown += async (_, e) => { if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await (CheckCompletion = ContinueAsync()); } };
        Activated += (_, _) => RefreshTheme(); Deactivated += (_, _) => RefreshTheme();
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        Closed += (_, _) =>
        {
            if (closed) return; closed = true; observer.Stop(); this.lifetime.Cancel();
            foreach (var popup in popups.Keys.ToArray()) popup.Close(); popups.Clear();
            page.Dispose(); completion.TrySetResult(false); SystemEvents.UserPreferenceChanged -= PreferenceChanged; this.lifetime.Dispose();
        };
        RefreshTheme();
    }
    internal async Task StartAsync(string? baseline, Func<CancellationToken, Task<string?>> readProfileFingerprint)
    {
        this.baseline = baseline; baselineKnown = true; this.readProfileFingerprint = readProfileFingerprint;
        try
        {
            var runtime = await environment.WaitAsync(cancellation);
            await page.Initialize(runtime, cancellation); fixture?.Invoke(page.Core); Configure(page, this);
            RefreshBrowserTheme();
            await page.Navigate(new Uri(provider.Origin, provider.LoginPath), cancellation);
            if (provider.WatchSignIn) { observer.Start(); await ObserveAsync(); }
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
    }
    internal static string? Fingerprint(JsonElement evidence)
        => evidence.ValueKind == JsonValueKind.String && evidence.GetString() is { Length: 64 } hash && hash.All(Uri.IsHexDigit) ? hash.ToLowerInvariant() : null;
    internal void Abort() { if (closed) return; allowClose = true; completion.TrySetResult(false); Close(); }
    private Task ContinueAsync() => page.IsUsable ? FinishAsync(requiringSession: true) : Task.CompletedTask;
    private async Task<string?> PageFingerprint(CancellationToken token)
    {
        if (provider.ID == "claude") return (await ClaudeWebCookies.ReadAsync(page.Core, token))?.SessionHash;
        return Fingerprint(await page.Evaluate(DeepSeekWebScripts.Shared.SignedIn, token));
    }
    private async Task ObserveAsync()
    {
        if (!provider.WatchSignIn || closed || checking || finishing || !page.IsUsable || !provider.IsOrigin(page.Core.Source)) return;
        checking = true;
        SessionChecks++;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(ProviderWebSession.ReadTimeout);
            string? current = await PageFingerprint(deadline.Token);
            if (closed || finishing) return;
            bool changed = current != null && current != baseline;
            if (changed && !signedIn)
            {
                signedIn = true; message.Text = ui.Text(provider.ID + ".login.signed_in_detail"); proceed.Content = ui.Text("login.done");
                refresh.Visibility = later.Visibility = Visibility.Collapsed;
                AutomationProperties.SetName(proceed, (string)proceed.Content);
                message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSuccess");
                _ = AutoCloseAsync(++autoCloseRevision);
            }
            else if (!changed && signedIn)
            {
                signedIn = false; autoCloseRevision++; message.Text = ui.Text("windows." + provider.ID + ".login.instructions"); proceed.Content = ui.Text("claude.login.continue");
                AutomationProperties.SetName(proceed, (string)proceed.Content); message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                refresh.Visibility = later.Visibility = Visibility.Visible;
            }
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) message.Text = ui.Text("claude.login.load_failed"); }
        finally { checking = false; }
    }
    private async Task AutoCloseAsync(int revision)
    {
        try { await Task.Delay(TimeSpan.FromMilliseconds(1500), cancellation); if (!closed && signedIn && revision == autoCloseRevision) await (CheckCompletion = FinishAsync(requiringSession: true)); }
        catch (OperationCanceledException) { }
    }
    private async Task FinishAsync(bool requiringSession)
    {
        if (closed || finishing || !baselineKnown || readProfileFingerprint == null) return;
        if (!page.IsUsable) { Abort(); return; }
        finishing = true;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(ProviderWebSession.StartupTimeout + ProviderWebSession.ReadTimeout);
            string? current = await readProfileFingerprint(deadline.Token);
            if (closed) return;
            if (current == null && requiringSession)
            {
                if (!provider.WatchSignIn) message.Text = ui.Text("harness.account.sign_in_again");
                return;
            }
            NewSession = current != null && current != baseline;
            completion.TrySetResult(current != null); allowClose = true; Close();
        }
        catch (Exception error) when (Recoverable(error))
        {
            if (!closed && !requiringSession) Abort();
            else if (!closed) message.Text = ui.Text("claude.login.load_failed");
        }
        finally { finishing = false; }
    }
    private void Configure(ProviderBrowserPage browser, Window window)
    {
        browser.Core.NavigationStarting += (_, e) => { if (!AllowedNavigation(e.Uri)) e.Cancel = true; };
        browser.Core.SourceChanged += (_, _) => { if (ReferenceEquals(browser, page) && browser.IsUsable) { address.Text = Host(browser.Core.Source); Title = ui.Text(provider.ID + ".login.title") + " · " + address.Text; } };
        browser.Core.NavigationCompleted += (_, e) =>
        {
            if (ReferenceEquals(browser, page) && !e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                message.Text = ui.Text("claude.login.load_failed");
            if (e.IsSuccess && ReferenceEquals(browser, page)) _ = ObserveAsync();
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
            WindowRendering.Prepare(window); window.Show(); await browser.Initialize(await environment.WaitAsync(cancellation), cancellation); fixture?.Invoke(browser.Core);
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
