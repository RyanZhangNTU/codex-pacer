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

/// Owned-profile sign-in, as on the Mac: a strip in the service's color above the site's page says what signing in
/// shows. A new sign-in turns it green and closes the window shortly after, so there is nothing to confirm. Claude and
/// DeepSeek compare the page's session with the one the window opened with; a service that confirms by reading
/// (WorkBuddy) reads its account through the window's profile every few seconds, wherever the page has gone.
internal class ProviderLoginWindow : Window
{
    private enum Phase { Prompt, LoadFailed, SignedIn }
    internal static readonly TimeSpan AutoCloseDelay = TimeSpan.FromMilliseconds(1500);
    internal static readonly TimeSpan ReadingInterval = TimeSpan.FromSeconds(3);
    internal static readonly TimeSpan SlowReadingInterval = TimeSpan.FromSeconds(10), ReadingSlowdown = TimeSpan.FromMinutes(2);
    private DateTime readingSince = DateTime.UtcNow;
    private static readonly Color Confirmed = Color.FromRgb(48, 186, 85);
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
    private readonly Border banner = new() { Padding = new Thickness(14, 10, 14, 10), BorderThickness = new Thickness(0, 0, 0, 1) };
    private readonly ContentControl mark = new() { Width = 28, Height = 28, Margin = new Thickness(0, 0, 11, 0), Focusable = false, IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly FrameworkElement providerMark;
    private readonly IconGlyph confirmedMark = new() { Symbol = "checkmark.circle.fill", Width = 26, Height = 26, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock heading = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock detail = new() { FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 1, 0, 0) };
    private readonly Button refresh = new() { Background = Brushes.Transparent, Padding = new Thickness(6, 0, 6, 0), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center, ContentTemplate = null };
    private readonly Button later = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Button done = new() { VerticalAlignment = VerticalAlignment.Center, IsDefault = true, Visibility = Visibility.Collapsed };
    private Phase phase = Phase.Prompt;
    private bool checking, closed, finishing, allowClose, baselineKnown, signedIn;
    private int autoCloseRevision;
    private string? baseline, confirmed;
    private Func<CancellationToken, Task<string?>>? readProfileFingerprint;
    private readonly DispatcherTimer observer = new();
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
        Title = TitleFor(provider.Origin.IdnHost); MinWidth = 420; MinHeight = 400; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SetResourceReference(BackgroundProperty, "SettingsBackground");
        observer.Interval = provider.ConfirmByReading ? ReadingInterval : TimeSpan.FromSeconds(1);

        providerMark = ProviderIcon.Create(provider.ID, 28);
        confirmedMark.SetResourceReference(IconGlyph.InkProperty, "SettingsSuccess");
        heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        banner.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator");
        var reload = new IconGlyph { Symbol = "arrow.clockwise", Width = 14, Height = 14 };
        reload.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        refresh.Content = reload; refresh.ToolTip = ui.Text("common.refresh");
        later.Content = ui.Text("login.later"); done.Content = ui.Text("login.done");
        done.SetResourceReference(StyleProperty, "SettingsProminentButton");
        AutomationProperties.SetAutomationId(banner, provider.ID + ".login.banner");
        AutomationProperties.SetAutomationId(heading, provider.ID + ".login.heading"); AutomationProperties.SetAutomationId(detail, provider.ID + ".login.detail");
        AutomationProperties.SetAutomationId(refresh, provider.ID + ".login.refresh"); AutomationProperties.SetName(refresh, ui.Text("common.refresh"));
        AutomationProperties.SetAutomationId(later, provider.ID + ".login.later"); AutomationProperties.SetAutomationId(done, provider.ID + ".login.done");
        AutomationProperties.SetLiveSetting(heading, AutomationLiveSetting.Polite);

        var strip = new Grid();
        strip.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); strip.ColumnDefinitions.Add(new()); strip.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; words.Children.Add(heading); words.Children.Add(detail);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(refresh); actions.Children.Add(later); actions.Children.Add(done);
        strip.Children.Add(mark); Grid.SetColumn(words, 1); strip.Children.Add(words); Grid.SetColumn(actions, 2); strip.Children.Add(actions);
        banner.Child = strip;
        ClientContent.RowDefinitions.Add(new() { Height = GridLength.Auto }); ClientContent.RowDefinitions.Add(new());
        ClientContent.Children.Add(banner);
        page = new(this, provider, closeWindow: false); Grid.SetRow(page.View, 1); ClientContent.Children.Add(page.View);
        Content = ClientContent; SetInitialContentSize(this, ClientContent, 760, 800);
        Present(Phase.Prompt);

        refresh.Click += (_, _) => Reload();
        later.Click += (_, _) => Close();
        done.Click += async (_, _) => await (CheckCompletion = FinishAsync(requiringSession: true));
        observer.Tick += async (_, _) =>
        {
            // A window left open stops asking the account every few seconds.
            if (provider.ConfirmByReading && DateTime.UtcNow - readingSince > ReadingSlowdown) observer.Interval = SlowReadingInterval;
            await ObserveAsync();
        };
        Closing += async (_, e) =>
        {
            if (allowClose || closed) return;
            e.Cancel = true;
            // Leave WPF's Closing stack before a completed probe or Abort calls Close again.
            await Dispatcher.Yield(DispatcherPriority.Background);
            if (closed) return;
            // A window that confirms by reading returns only the reading it confirmed, as on the Mac.
            if (!baselineKnown || provider.ConfirmByReading && confirmed == null) { Abort(); return; }
            await (CheckCompletion = FinishAsync(requiringSession: false));
        };
        // Ctrl+Enter completes now when the profile has a session, as ⌘Return does on the Mac.
        PreviewKeyDown += async (_, e) => { if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; await FinishNow(); } };
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
            readingSince = DateTime.UtcNow; observer.Start();
            // A reading waits for the first interval, as on the Mac, so it doesn't race the page's own load.
            if (!provider.ConfirmByReading) await ObserveAsync();
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed) Present(Phase.LoadFailed); }
    }
    internal static string? Fingerprint(JsonElement evidence)
        => evidence.ValueKind == JsonValueKind.String && evidence.GetString() is { Length: 64 } hash && hash.All(Uri.IsHexDigit) ? hash.ToLowerInvariant() : null;
    internal void Abort() { if (closed) return; allowClose = true; completion.TrySetResult(false); Close(); }
    /// The Ctrl+Enter shortcut: completes now if the profile has a session, and otherwise keeps the window open.
    internal Task FinishNow() => CheckCompletion = page.IsUsable || confirmed != null ? FinishAsync(requiringSession: true) : Task.CompletedTask;
    private string TitleFor(string host) => ui.Text(provider.ID + ".login.title") + " · " + host;
    private void Present(Phase next)
    {
        phase = next;
        bool success = next == Phase.SignedIn;
        mark.Content = success ? confirmedMark : providerMark;
        heading.Text = ui.Text(provider.ID + (success ? ".login.signed_in" : ".login.prompt"));
        detail.Text = next switch
        {
            Phase.LoadFailed => ui.Text("claude.login.load_failed"),
            Phase.SignedIn => ui.Text(provider.ID + ".login.signed_in_detail"),
            _ => ui.Text(provider.ID + ".login.prompt_detail")
        };
        detail.SetResourceReference(TextBlock.ForegroundProperty, next == Phase.LoadFailed ? "SettingsWarning" : "SettingsSecondary");
        refresh.Visibility = later.Visibility = success ? Visibility.Collapsed : Visibility.Visible;
        done.Visibility = success ? Visibility.Visible : Visibility.Collapsed;
        PaintBanner();
    }
    /// The service's color at 16%, green once signed in; high contrast keeps the system's own surfaces.
    private void PaintBanner()
    {
        Color tint = phase == Phase.SignedIn ? Confirmed : PacerPalette.BrandColor(provider.ID);
        banner.Background = SystemParameters.HighContrast ? Brushes.Transparent : new SolidColorBrush(Color.FromArgb(41, tint.R, tint.G, tint.B));
    }
    private void Reload()
    {
        if (!page.IsUsable) return;
        if (phase == Phase.LoadFailed) Present(Phase.Prompt);
        try { page.Core.Reload(); }
        catch (Exception error) when (Recoverable(error)) { Present(Phase.LoadFailed); }
    }
    private async Task<string?> PageFingerprint(CancellationToken token)
    {
        if (provider.ID == "claude") return (await ClaudeWebCookies.ReadAsync(page.Core, token))?.SessionHash;
        return Fingerprint(await page.Evaluate(DeepSeekWebScripts.Shared.SignedIn, token));
    }
    private async Task ObserveAsync()
    {
        if (closed || checking || finishing || provider.ConfirmByReading && (signedIn || readProfileFingerprint == null)) return;
        if (!provider.ConfirmByReading && (!page.IsUsable || !provider.IsOrigin(page.Core.Source))) return;
        checking = true;
        SessionChecks++;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            string? current;
            if (provider.ConfirmByReading)
            {
                deadline.CancelAfter(ProviderWebSession.StartupTimeout + ProviderWebSession.ReadTimeout);
                current = await readProfileFingerprint!(deadline.Token);
            }
            else { deadline.CancelAfter(ProviderWebSession.ReadTimeout); current = await PageFingerprint(deadline.Token); }
            if (closed || finishing) return;
            // A reading confirms by itself; a page session must differ from the one the window opened with.
            bool changed = current != null && (provider.ConfirmByReading || current != baseline);
            if (changed && !signedIn)
            {
                signedIn = true;
                if (provider.ConfirmByReading) { confirmed = current; observer.Stop(); }
                Present(Phase.SignedIn);
                _ = AutoCloseAsync(++autoCloseRevision);
            }
            else if (!changed && signedIn) { signedIn = false; autoCloseRevision++; Present(Phase.Prompt); }
        }
        // A failed check is retried on the next tick; the page itself reports load failures.
        catch (Exception error) when (Recoverable(error)) { }
        finally { checking = false; }
    }
    private async Task AutoCloseAsync(int revision)
    {
        try { await Task.Delay(AutoCloseDelay, cancellation); if (!closed && signedIn && revision == autoCloseRevision) await (CheckCompletion = FinishAsync(requiringSession: true)); }
        catch (OperationCanceledException) { }
    }
    private async Task FinishAsync(bool requiringSession)
    {
        if (closed || finishing || !baselineKnown || readProfileFingerprint == null) return;
        if (!page.IsUsable && confirmed == null) { Abort(); return; }
        finishing = true;
        try
        {
            string? current = confirmed;
            if (current == null)
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(ProviderWebSession.StartupTimeout + ProviderWebSession.ReadTimeout);
                current = await readProfileFingerprint(deadline.Token);
            }
            if (closed) return;
            // Without a session, Done and Ctrl+Enter keep the window open, while closing it simply closes.
            if (current == null && requiringSession) return;
            NewSession = current != null && current != baseline;
            completion.TrySetResult(current != null); allowClose = true; Close();
        }
        catch (Exception error) when (Recoverable(error))
        {
            if (!closed && !requiringSession) Abort();
            else if (!closed) Present(Phase.LoadFailed);
        }
        finally { finishing = false; }
    }
    private void Configure(ProviderBrowserPage browser, Window window)
    {
        browser.Core.NavigationStarting += (_, e) => { if (!AllowedNavigation(e.Uri)) e.Cancel = true; };
        browser.Core.SourceChanged += (_, _) => { if (ReferenceEquals(browser, page) && browser.IsUsable) Title = TitleFor(Host(browser.Core.Source)); };
        browser.Core.NavigationCompleted += (_, e) =>
        {
            if (ReferenceEquals(browser, page) && !e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled && phase == Phase.Prompt)
                Present(Phase.LoadFailed);
            if (e.IsSuccess && ReferenceEquals(browser, page) && !provider.ConfirmByReading) _ = ObserveAsync();
        };
        browser.Core.WindowCloseRequested += (_, _) => window.Close();
        browser.Core.ProcessFailed += (_, _) => { if (!closed && ReferenceEquals(browser, page) && phase == Phase.Prompt) Present(Phase.LoadFailed); };
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
        catch (Exception error) when (Recoverable(error)) { window?.Close(); if (!closed && phase == Phase.Prompt) Present(Phase.LoadFailed); }
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
        PaintBanner();
        if (page.IsUsable) RefreshBrowserTheme();
    }
    private void RefreshBrowserTheme()
    {
        try
        {
            if (page.IsUsable) page.Core.Profile.PreferredColorScheme = darkOverride is bool dark ?
                dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light : CoreWebView2PreferredColorScheme.Auto;
        }
        catch (Exception error) when (Recoverable(error)) { if (!closed && phase == Phase.Prompt) Present(Phase.LoadFailed); }
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
