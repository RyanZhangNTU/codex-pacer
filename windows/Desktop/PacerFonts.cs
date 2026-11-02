using System;
using System.Globalization;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class PacerFonts
{
    // Code-created families need an explicit base URI. An absolute pack URI
    // passed as a family name does not resolve the embedded face in WPF.
    internal static readonly FontFamily Interface = new(
        new Uri("pack://application:,,,/CodexPacer;component/"), "./Assets/Fonts/#Inter");
    // Use the same inherited language for vector text and TextBlock fallback.
    // The machine's numeric/date culture remains independent of UI language.
    internal static CultureInfo Culture(FrameworkElement element) => element.Language.GetEquivalentCulture();
    internal static XmlLanguage RenderingLanguage(UiText ui) => XmlLanguage.GetLanguage(ui.Language == "zh-Hans" ? "zh-Hans" : "en-US");
}
