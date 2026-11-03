using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

internal interface IClaudeWebSession : IAsyncDisposable
{
    bool Available { get; }
    bool SignInWasNew => true;
    Task PrepareAsync(CancellationToken cancellation) => Task.CompletedTask;
    Task<ClaudeWebSessionValue?> ReadAsync(CancellationToken cancellation);
    Task<bool> SignInAsync();
    Task ClearAsync(CancellationToken cancellation);
}

internal sealed class ClaudeWebSession : ProviderWebSession, IClaudeWebSession
{
    // The native client probes cookies before and after its HTTPS read. Keep
    // one owned blank controller alive so those probes do not race browser exit.
    protected override bool KeepBrowserAlive => true;
    protected override bool ReuseReader => true;
    internal ClaudeWebSession(UiText ui) : this(ui,
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "Web", "Claude"), null, null) { }
    internal ClaudeWebSession(UiText ui, string directory, Action<CoreWebView2>? fixture, bool? darkOverride)
        : base(ui, ProviderWebDefinition.Claude, directory, fixture, darkOverride) { }
    protected override ProviderLoginWindow CreateLogin(Task<CoreWebView2Environment> environment, CancellationToken lifetime)
        => new ClaudeLoginWindow(ui, environment, fixture, darkOverride, lifetime);
    protected override async Task<string?> ReadFingerprintAsync(CancellationToken cancellation)
        => (await ReadAsync(cancellation))?.SessionHash;
    public Task<ClaudeWebSessionValue?> ReadAsync(CancellationToken cancellation) => base.ReadAsync((page, token) => ClaudeWebCookies.ReadAsync(page.Core, token), cancellation);
}
