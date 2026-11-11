using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

internal interface IDeepSeekWebSession : IAsyncDisposable
{
    bool Available { get; }
    bool SignInWasNew => true;
    Task<DeepSeekWebReply> ReadAsync(CancellationToken cancellation);
    Task<bool> SignInAsync();
    Task ClearAsync(CancellationToken cancellation);
}

internal sealed class DeepSeekWebSession : ProviderWebSession, IDeepSeekWebSession
{
    internal DeepSeekWebSession(UiText ui) : this(ui,
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "Web", "DeepSeek"), null, null) { }
    internal DeepSeekWebSession(UiText ui, string directory, Action<CoreWebView2>? fixture, bool? darkOverride)
        : base(ui, ProviderWebDefinition.DeepSeek, directory, fixture, darkOverride) { }
    protected override ProviderLoginWindow CreateLogin(Task<CoreWebView2Environment> environment, CancellationToken lifetime)
        => new DeepSeekLoginWindow(ui, environment, fixture, darkOverride, lifetime);
    protected override Task<string?> ReadFingerprintAsync(CancellationToken cancellation) => base.ReadAsync(async (page, token) =>
    {
        await page.NavigateReader(new Uri(DeepSeekWebScripts.Origin, ".codex-pacer/balance/" + Guid.NewGuid().ToString("N")), token);
        return ProviderLoginWindow.Fingerprint(await page.Evaluate(DeepSeekWebScripts.Shared.SignedIn, token));
    }, cancellation);
    // The engine bounds this read and cancels it via the host request token.
    public Task<DeepSeekWebReply> ReadAsync(CancellationToken cancellation) => base.ReadAsync(async (page, token) =>
    {
        await page.NavigateReader(new Uri(DeepSeekWebScripts.Origin, ".codex-pacer/balance/" + Guid.NewGuid().ToString("N")), token);
        return DeepSeekWebReply.FromPage(await page.Evaluate(DeepSeekWebScripts.Shared.Summary, token));
    }, cancellation, readTimeout: Timeout.InfiniteTimeSpan);
}
