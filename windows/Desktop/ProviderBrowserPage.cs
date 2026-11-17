using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace CodexPacer.Windows;

/// One controller in Pacer's own profile. Reader documents contain no site scripts.
internal class ProviderBrowserPage : IDisposable
{
    internal WebView2 View { get; } = new();
    private CoreWebView2? core;
    private bool processFailed;
    internal CoreWebView2 Core => core ?? throw new InvalidOperationException("The browser is not initialized.");
    internal bool IsUsable => core != null && !processFailed && !disposed;
    private readonly Window window;
    private readonly bool closeWindow;
    private readonly ProviderWebDefinition provider;
    private bool disposed;
    private readonly HashSet<ulong> loading = [];
    /// A navigation has started and not finished. One that fails meanwhile was replaced by the page itself:
    /// workbuddy.cn's script sends its usage page to its sign-in page while the first page still loads, and
    /// WebView2 ends that first navigation as aborted (11/17, the window called it a load failure).
    internal bool Loading => loading.Count > 0;
    internal ProviderBrowserPage(Window window, ProviderWebDefinition provider, bool closeWindow = true)
    { this.window = window; this.provider = provider; this.closeWindow = closeWindow; }
    internal async Task Initialize(CoreWebView2Environment environment, CancellationToken cancellation)
    {
        try
        {
            await View.EnsureCoreWebView2Async(environment).WaitAsync(cancellation);
            cancellation.ThrowIfCancellationRequested();
            core = View.CoreWebView2;
            // First, so every later handler sees the finished navigation gone. A navigation cancelled while
            // starting still completes, as OperationCanceled.
            core.NavigationStarting += (_, e) => loading.Add(e.NavigationId);
            core.NavigationCompleted += (_, e) => loading.Remove(e.NavigationId);
            core.ProcessFailed +=(_, e) => { if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited) processFailed = true; };
            var settings = Core.Settings;
            settings.AreDevToolsEnabled = false; settings.AreHostObjectsAllowed = false; settings.IsWebMessageEnabled = false;
            settings.IsStatusBarEnabled = false; settings.IsPasswordAutosaveEnabled = false; settings.IsGeneralAutofillEnabled = false;
            Core.DownloadStarting += (_, e) => e.Cancel = true;
        }
        catch { Dispose(); throw; }
    }
    private Uri? reader;
    /// A kept page becomes a reader once and stays one: its request filter and
    /// navigation lock belong to one document, and a second reader would stack them.
    internal async Task UseReader(Func<Uri> blank, CancellationToken cancellation)
    {
        if (reader != null)
        {
            if (Core.Source == reader.AbsoluteUri) return;
            throw new IOException("The reader page left its document.");
        }
        reader = blank(); await NavigateReader(reader, cancellation);
    }
    internal async Task NavigateReader(Uri blank, CancellationToken cancellation)
    {
        Core.Settings.IsScriptEnabled = false; Core.Settings.AreDefaultContextMenusEnabled = false;
        Core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        Core.WebResourceRequested += (_, e) =>
        {
            if (e.Request.Uri == blank.AbsoluteUri && e.ResourceContext == CoreWebView2WebResourceContext.Document && e.Request.Method == "GET")
            {
                e.Response = Core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes("<!doctype html><title>Pacer</title>")),
                    200, "OK", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; connect-src " + provider.Origin.GetLeftPart(UriPartial.Authority));
            }
            else if (!provider.IsReaderRequest(e.Request.Uri, e.Request.Method))
                e.Response = Core.Environment.CreateWebResourceResponse(new MemoryStream(), 403, "Forbidden", "Cache-Control: no-store");
        };
        Core.NavigationStarting += (_, e) => { if (e.Uri != blank.AbsoluteUri) e.Cancel = true; };
        Core.NewWindowRequested += (_, e) => e.Handled = true;
        await Core.CallDevToolsProtocolMethodAsync("Network.setBypassServiceWorker", "{\"bypass\":true}").WaitAsync(cancellation);
        await Core.CallDevToolsProtocolMethodAsync("Network.setCacheDisabled", "{\"cacheDisabled\":true}").WaitAsync(cancellation);
        await Navigate(blank, cancellation);
    }
    internal async Task Navigate(Uri uri, CancellationToken cancellation)
    {
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        // The page's own newer navigation reports instead of the one it replaced.
        void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs e) { if (e.IsSuccess || !Loading) ready.TrySetResult(e.IsSuccess); }
        Core.NavigationCompleted += Completed;
        try
        {
            Core.Navigate(uri.AbsoluteUri);
            if (!await ready.Task.WaitAsync(cancellation)) throw new IOException("The browser document could not load.");
        }
        finally { Core.NavigationCompleted -= Completed; }
    }
    internal async Task<JsonElement> Evaluate(string script, CancellationToken cancellation)
    {
        if (!IsUsable || !provider.IsOrigin(Core.Source)) throw new IOException("The browser origin changed.");
        using var tree = JsonDocument.Parse(await Core.CallDevToolsProtocolMethodAsync("Page.getFrameTree", "{}").WaitAsync(cancellation));
        string id = tree.RootElement.GetProperty("frameTree").GetProperty("frame").GetProperty("id").GetString() ?? throw new IOException();
        using var world = JsonDocument.Parse(await Core.CallDevToolsProtocolMethodAsync("Page.createIsolatedWorld",
            JsonSerializer.Serialize(new { frameId = id, worldName = provider.WorldName, grantUniveralAccess = false })).WaitAsync(cancellation));
        int context = world.RootElement.GetProperty("executionContextId").GetInt32();
        string raw = await Core.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
            JsonSerializer.Serialize(new { expression = "(async () => {\n" + script + "\n})()", contextId = context, awaitPromise = true,
                returnByValue = true, silent = true, generatePreview = false })).WaitAsync(cancellation);
        if (raw.Length > 64 * 1024) throw new IOException("The browser reply is too large.");
        using var result = JsonDocument.Parse(raw);
        if (!IsUsable || !provider.IsOrigin(Core.Source) || result.RootElement.TryGetProperty("exceptionDetails", out _) ||
            !result.RootElement.GetProperty("result").TryGetProperty("value", out var value)) throw new IOException("The browser read could not complete.");
        return value.Clone();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        View.Dispose(); if (closeWindow) window.Close();
    }
}
