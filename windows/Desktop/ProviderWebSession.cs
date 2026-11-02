using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

/// Each service owns an app-private profile, shared only by its reader/login controllers.
internal abstract class ProviderWebSession : IAsyncDisposable
{
    private readonly string directory;
    protected readonly UiText ui;
    protected readonly bool? darkOverride;
    protected readonly Action<CoreWebView2>? fixture;
    private readonly ProviderWebDefinition provider;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim operation = new(1, 1);
    private Task<CoreWebView2Environment>? environment;
    private CancellationTokenSource? activeRead;
    private ProviderLoginWindow? login;
    private ProviderBrowserPage? browserKeeper;
    private int revision;
    private bool clearing, disposed;
    protected ProviderWebSession(UiText ui, ProviderWebDefinition provider, string directory, Action<CoreWebView2>? fixture, bool? darkOverride)
    { this.ui = ui; this.provider = provider; this.directory = Path.GetFullPath(directory); this.fixture = fixture; this.darkOverride = darkOverride; }
    protected abstract ProviderLoginWindow CreateLogin(Task<CoreWebView2Environment> environment, CancellationToken lifetime);
    protected virtual bool KeepBrowserAlive => false;
    protected virtual bool ReuseReader => false;
    private void RetainBrowser(ref ProviderBrowserPage? page)
    {
        if (!KeepBrowserAlive || disposed || page is not { IsUsable: true }) return;
        var previous = browserKeeper; browserKeeper = page; page = null; previous?.Dispose();
    }
    public bool Available
    {
        get
        {
            try { return !disposed && !string.IsNullOrEmpty(CoreWebView2Environment.GetAvailableBrowserVersionString(null, Options())); }
            catch (Exception error) when (error is IOException or COMException or DllNotFoundException or BadImageFormatException or WebView2RuntimeNotFoundException) { return false; }
        }
    }
    private async Task<CoreWebView2Environment> EnvironmentAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var pending = environment ??= CreateEnvironment();
        try { return await pending; }
        catch { if (ReferenceEquals(environment, pending)) environment = null; throw; }
    }
    private async Task<CoreWebView2Environment> CreateEnvironment()
    {
        var value = await CoreWebView2Environment.CreateAsync(null, directory, Options());
        value.BrowserProcessExited += (_, _) =>
        {
            if (environment is { IsCompletedSuccessfully: true } current && ReferenceEquals(current.Result, value)) environment = null;
        };
        return value;
    }
    private static CoreWebView2EnvironmentOptions Options() => new() { AreBrowserExtensionsEnabled = false, ReleaseChannels = CoreWebView2ReleaseChannels.Stable };
    protected async Task<T> ReadAsync<T>(Func<ProviderBrowserPage, CancellationToken, Task<T>> inspect, CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        int current = revision;
        using var read = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        read.CancelAfter(TimeSpan.FromSeconds(20));
        await operation.WaitAsync(read.Token);
        ProviderBrowserPage? page = null;
        try
        {
            if (clearing || current != revision) throw new OperationCanceledException();
            activeRead = read;
            if (ReuseReader && browserKeeper is { IsUsable: true }) { page = browserKeeper; browserKeeper = null; }
            else
            {
                var runtime = await EnvironmentAsync().WaitAsync(read.Token);
                var window = new Window { Width = 320, Height = 240, Left = -32000, Top = -32000, Opacity = 0,
                    ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None };
                page = new(window, provider); window.Content = page.View; WindowRendering.Prepare(window); window.Show();
                await page.Initialize(runtime, read.Token);
            }
            fixture?.Invoke(page.Core);
            var reply = await inspect(page, read.Token);
            if (clearing || current != revision) throw new OperationCanceledException();
            return reply;
        }
        finally
        {
            if (ReuseReader || !clearing && !read.IsCancellationRequested) RetainBrowser(ref page);
            page?.Dispose(); if (ReferenceEquals(activeRead, read)) activeRead = null; operation.Release();
        }
    }
    public async Task<bool> SignInAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (clearing) return false;
        if (login != null) { login.Activate(); return await login.Completion; }
        var window = CreateLogin(EnvironmentAsync(), lifetime.Token);
        login = window;
        try { window.Show(); await window.StartAsync(); return await window.Completion; }
        finally { if (ReferenceEquals(login, window)) login = null; window.Close(); }
    }
    public async Task ClearAsync(CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (clearing) throw new IOException("The profile is already changing.");
        revision++; clearing = true; activeRead?.Cancel(); login?.Close();
        bool entered = false;
        ProviderBrowserPage? page = null;
        try
        {
            await operation.WaitAsync(cancellation); entered = true;
            if (!Directory.Exists(directory)) return;
            var runtime = await EnvironmentAsync().WaitAsync(cancellation);
            var window = new Window { Width = 1, Height = 1, Left = -32000, Top = -32000, Opacity = 0, ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None };
            page = new(window, provider); window.Content = page.View; WindowRendering.Prepare(window); window.Show();
            await page.Initialize(runtime, cancellation);
            await page.Core.Profile.ClearBrowsingDataAsync().WaitAsync(cancellation);
        }
        finally
        {
            if (!cancellation.IsCancellationRequested) RetainBrowser(ref page);
            page?.Dispose(); clearing = false; if (entered) operation.Release();
        }
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; revision++; lifetime.Cancel(); activeRead?.Cancel(); login?.Close();
        await operation.WaitAsync(); browserKeeper?.Dispose(); browserKeeper = null; operation.Release();
        lifetime.Dispose();
    }
}
