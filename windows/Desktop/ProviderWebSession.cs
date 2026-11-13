using System;
using System.Diagnostics;
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
    internal static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(60);
    internal static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(20);
    internal Action<string, TimeSpan>? StartupMeasured { get; set; }
    protected ProviderWebSession(UiText ui, ProviderWebDefinition provider, string directory, Action<CoreWebView2>? fixture, bool? darkOverride)
    { this.ui = ui; this.provider = provider; this.directory = Path.GetFullPath(directory); this.fixture = fixture; this.darkOverride = darkOverride; }
    protected abstract ProviderLoginWindow CreateLogin(Task<CoreWebView2Environment> environment, CancellationToken lifetime);
    protected abstract Task<string?> ReadFingerprintAsync(CancellationToken cancellation);
    public bool SignInWasNew { get; private set; }
    protected virtual bool KeepBrowserAlive => false;
    protected virtual bool ReuseReader => false;
    private void RetainBrowser(ref ProviderBrowserPage? page)
    {
        if (!KeepBrowserAlive || disposed || page is not { IsUsable: true }) return;
        var previous = browserKeeper; browserKeeper = page; page = null; previous?.Dispose();
    }
    /// Created by the first sign-in window or read; absent, there is nothing to read.
    public bool HasProfile
    {
        get { try { return Directory.Exists(directory); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return true; } }
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
    private async Task<ProviderBrowserPage> CreateReader(CancellationToken cancellation)
    {
        using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        startup.CancelAfter(StartupTimeout);
        ProviderBrowserPage? page = null;
        string stage = "environment";
        var clock = Stopwatch.StartNew();
        try
        {
            var runtime = await EnvironmentAsync().WaitAsync(startup.Token);
            StartupMeasured?.Invoke(stage, clock.Elapsed);
            stage = "controller"; clock.Restart();
            var window = new Window { Width = 320, Height = 240, Left = -32000, Top = -32000, Opacity = 0,
                ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize };
            page = new(window, provider); window.Content = page.View; WindowRendering.Prepare(window); WindowRendering.KeepUnminimized(window); window.Show();
            await page.Initialize(runtime, startup.Token);
            StartupMeasured?.Invoke(stage, clock.Elapsed);
            return page;
        }
        catch (OperationCanceledException error) when (!cancellation.IsCancellationRequested)
        {
            StartupMeasured?.Invoke(stage + "-timeout", clock.Elapsed);
            page?.Dispose();
            throw new IOException("The private browser " + stage + " startup timed out.", error);
        }
        catch { page?.Dispose(); throw; }
    }
    // Warm only the owned blank controller; no site navigation or cookie read.
    // The same operation gate lets reads reuse it and lets clearing cancel it.
    public async Task PrepareAsync(CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!KeepBrowserAlive) return;
        int current = revision;
        using var warm = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        using var queue = CancellationTokenSource.CreateLinkedTokenSource(warm.Token);
        queue.CancelAfter(ReadTimeout);
        await operation.WaitAsync(queue.Token);
        ProviderBrowserPage? page = null;
        try
        {
            if (clearing || current != revision) throw new OperationCanceledException();
            activeRead = warm;
            if (browserKeeper is { IsUsable: true }) return;
            page = await CreateReader(warm.Token);
            warm.Token.ThrowIfCancellationRequested();
            if (clearing || current != revision) throw new OperationCanceledException();
            RetainBrowser(ref page);
        }
        finally
        {
            page?.Dispose(); if (ReferenceEquals(activeRead, warm)) activeRead = null; operation.Release();
        }
    }
    protected async Task<T> ReadAsync<T>(Func<ProviderBrowserPage, CancellationToken, Task<T>> inspect,
        CancellationToken cancellation, TimeSpan? readTimeout = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        int current = revision;
        TimeSpan timeout = readTimeout ?? ReadTimeout;
        using var read = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        using var queue = CancellationTokenSource.CreateLinkedTokenSource(read.Token);
        queue.CancelAfter(timeout);
        await operation.WaitAsync(queue.Token);
        ProviderBrowserPage? page = null;
        bool completed = false;
        try
        {
            if (clearing || current != revision) throw new OperationCanceledException();
            activeRead = read;
            if (ReuseReader && browserKeeper is { IsUsable: true }) { page = browserKeeper; browserKeeper = null; }
            else page = await CreateReader(read.Token);
            using var inspection = CancellationTokenSource.CreateLinkedTokenSource(read.Token);
            inspection.CancelAfter(timeout);
            fixture?.Invoke(page.Core);
            var reply = await inspect(page, inspection.Token);
            inspection.Token.ThrowIfCancellationRequested();
            if (clearing || current != revision) throw new OperationCanceledException();
            completed = true;
            return reply;
        }
        finally
        {
            if (completed && !clearing && !read.IsCancellationRequested) RetainBrowser(ref page);
            page?.Dispose(); if (ReferenceEquals(activeRead, read)) activeRead = null; operation.Release();
        }
    }
    public Task<bool> SignInAsync() => SignInAsync(CancellationToken.None);

    public async Task<bool> SignInAsync(CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (clearing) return false;
        if (login is { } existing) { if (existing.IsVisible) existing.Activate(); bool result = await existing.Completion; SignInWasNew = result && existing.NewSession; return result; }
        revision++; activeRead?.Cancel(); SignInWasNew = false;
        var window = CreateLogin(EnvironmentAsync(), lifetime.Token);
        login = window;
        try
        {
            using var registration = cancellation.Register(() => window.Dispatcher.BeginInvoke(new Action(window.Abort)));
            cancellation.ThrowIfCancellationRequested();
            string? baseline = provider.WatchSignIn ? await ReadFingerprintAsync(lifetime.Token) : null;
            if (!window.Completion.IsCompleted) { window.Show(); await window.StartAsync(baseline, ReadFingerprintAsync); }
            bool result = await window.Completion; SignInWasNew = result && window.NewSession; return result;
        }
        finally { if (ReferenceEquals(login, window)) login = null; window.Abort(); }
    }
    public async Task ClearAsync(CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (clearing) throw new IOException("The profile is already changing.");
        revision++; clearing = true; activeRead?.Cancel(); login?.Abort();
        bool entered = false;
        ProviderBrowserPage? page = null;
        try
        {
            await operation.WaitAsync(cancellation); entered = true;
            if (!Directory.Exists(directory)) return;
            var runtime = await EnvironmentAsync().WaitAsync(cancellation);
            var window = new Window { Width = 1, Height = 1, Left = -32000, Top = -32000, Opacity = 0, ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize };
            page = new(window, provider); window.Content = page.View; WindowRendering.Prepare(window); WindowRendering.KeepUnminimized(window); window.Show();
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
        if (disposed) return; disposed = true; revision++; lifetime.Cancel(); activeRead?.Cancel(); login?.Abort();
        await operation.WaitAsync(); browserKeeper?.Dispose(); browserKeeper = null; operation.Release();
        lifetime.Dispose();
    }
}
