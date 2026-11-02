using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

internal sealed class DeepSeekLoginWindow : ProviderLoginWindow
{
    internal DeepSeekLoginWindow(UiText ui, Task<CoreWebView2Environment> environment, Action<CoreWebView2>? fixture, bool? darkOverride, CancellationToken lifetime)
        : base(ui, environment, fixture, darkOverride, lifetime, ProviderWebDefinition.DeepSeek) { }
}
