using System.Windows;

namespace CodexPacer.Windows;

internal sealed class DeepSeekBrowserPage : ProviderBrowserPage
{
    internal DeepSeekBrowserPage(Window window, bool closeWindow = true) : base(window, ProviderWebDefinition.DeepSeek, closeWindow) { }
}
