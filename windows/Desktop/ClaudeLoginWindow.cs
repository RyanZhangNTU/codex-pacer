using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

internal sealed class ClaudeLoginWindow : ProviderLoginWindow
{
    internal ClaudeLoginWindow(UiText ui, Task<CoreWebView2Environment> environment, Action<CoreWebView2>? fixture, bool? darkOverride, CancellationToken lifetime)
        : base(ui, environment, fixture, darkOverride, lifetime, ProviderWebDefinition.Claude) { }
}
