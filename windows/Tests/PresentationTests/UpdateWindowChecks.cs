using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

// Pacer's own update window in each state, both languages and themes:
// readable notes, real progress text and the expected default actions.
internal static class UpdateWindowChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans");
        await using var service = new WindowsUpdateService(action => action());
        const string notes = "Codex Pacer 4.2.3 improves **updates** on Windows.\n\n- Downloads show their progress.\n- `install.log` stays beside the update.\n\n" +
            "### Install\n\nSee the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) or <b>this</b>.";
        var package = new WindowsUpdatePackage("4.2.3", new(4, 2, 3, 75), "x64", new(10, 0, 19041), new Uri("https://github.com/RyanZhangNTU/codex-pacer"),
            178_786_767, Convert.ToBase64String(new byte[64]), notes);
        var window = new UpdateWindow(ui, service, "4.2.2", dark) { ShowActivated = false, IsHitTestVisible = false };
        string Name(string stage) => Path.Combine(output, $"update-{stage}-{language}-{(dark ? "dark" : "light")}.png");
        string Format(string key, params object[] values) => string.Format(CultureInfo.CurrentCulture, ui.Text(key), values);
        try
        {
            window.Show(); window.Offer(package, true); await Pump();
            Check(window.Current == UpdateWindow.Stage.Offer && Text(window, "update.title") == ui.Text("windows.updates.new_version_title")
                && Text(window, "update.status") == Format("windows.updates.new_version_detail", "4.2.3", "4.2.2") + "\n" + Format("windows.updates.download_size", "170.5 MB"),
                "The offer names the new and installed versions and the download size");
            Check(Find<Button>(window, "update.install").IsDefault && !Find<Button>(window, "update.later").IsDefault && Has(window, "update.skip"),
                "Install is the default action, with Later and Skip beside it");
            var viewer = Find<FlowDocumentScrollViewer>(window, "update.notes");
            var document = viewer.Document;
            Check(document.Blocks.Count == 4 && document.Blocks.ElementAt(1) is List { ListItems.Count: 2 }
                && document.Blocks.ElementAt(2) is Paragraph { FontWeight: var weight } && weight == FontWeights.SemiBold,
                "The signed Markdown renders as paragraphs, a list and a heading");
            string plain = new TextRange(document.ContentStart, document.ContentEnd).Text;
            Check(!plain.Contains("**") && plain.Contains("install.log") && plain.Contains("<b>this</b>")
                && document.Blocks.ElementAt(3) is Paragraph last && last.Inlines.OfType<Hyperlink>().Single().NavigateUri?.Host == "github.com",
                "Markup becomes formatting, HTML stays literal text, and only the GitHub link is a link");
            Color ink = ((SolidColorBrush)window.FindResource("SettingsPrimary")).Color, tile = ((SolidColorBrush)window.FindResource("SettingsTile")).Color;
            Check(document.Foreground is SolidColorBrush { Color: var shown } && shown == ink && viewer.Parent is Border { Background: SolidColorBrush { Color: var behind } } && behind == tile
                && Contrast(ink, tile) >= 4.5, "Release notes use the Settings palette with readable contrast in light and dark");
            Capture(window, Name("offer"));
            window.Offer(package with { Length = 21_400_000, Incremental = true }, true); await Pump();
            Check(Text(window, "update.status").EndsWith(Format("windows.updates.download_size_incremental", (21_400_000 / 1048576.0).ToString("0.0", CultureInfo.CurrentCulture) + " MB"), StringComparison.Ordinal),
                "A patch offer says it downloads only the changed files, with its own size");
            Capture(window, Name("offer-incremental"));
            window.BeginDownload(package); window.Report(new(42_100_000, package.Length)); await Pump();
            var progress = Find<ProgressBar>(window, "update.progress");
            Check(window.Current == UpdateWindow.Stage.Downloading && Math.Abs(progress.Value - 42_100_000.0 / package.Length) < 1e-9
                && Descendants(window).OfType<TextBlock>().Any(text => text.Text == Format("windows.updates.progress", (42_100_000 / 1048576.0).ToString("0.0", CultureInfo.CurrentCulture) + " MB", "170.5 MB", "24%"))
                && Has(window, "update.cancel"), "Downloading shows the real fraction, both sizes and Cancel");
            Capture(window, Name("downloading"));
            window.Report(new(package.Length, package.Length)); await Pump();
            Check(window.Current == UpdateWindow.Stage.Verifying && Text(window, "update.title") == ui.Text("windows.updates.verifying"), "A complete download is verified before it can install");
            window.ShowReady(package); await Pump();
            Check(window.Current == UpdateWindow.Stage.Ready && Find<Button>(window, "update.relaunch").IsDefault, "Install and Relaunch is the default once verified");
            Capture(window, Name("ready"));
            window.UpToDate(); await Pump();
            Check(Text(window, "update.status") == Format("windows.updates.up_to_date_detail", "4.2.2") && Find<Button>(window, "update.ok").IsDefault, "Up to date names the installed version");
            Capture(window, Name("current"));
            window.Failed(); await Pump();
            Check(Find<Button>(window, "update.retry").IsDefault && Has(window, "update.close"), "A failure offers Try Again and Close");
            Capture(window, Name("failed"));
            window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), 0, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent });
            await Pump();
            Check(!window.IsVisible && !service.Status.Busy, "Escape closes the window and ends the update operation");
        }
        finally { if (window.IsVisible) window.Close(); }
        Console.WriteLine("PASS update window " + language + (dark ? " dark" : " light") + ": full and patch offers with rendered notes, progress, verify, ready, up to date, failure and Escape");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static string Text(DependencyObject root, string id) => Find<TextBlock>(root, id).Text;
    private static double Contrast(Color first, Color second)
    {
        static double Channel(byte value) { double normalized = value / 255.0; return normalized <= 0.04045 ? normalized / 12.92 : Math.Pow((normalized + 0.055) / 1.055, 2.4); }
        static double Luminance(Color value) => 0.2126 * Channel(value.R) + 0.7152 * Channel(value.G) + 0.0722 * Channel(value.B);
        double a = Luminance(first), b = Luminance(second); return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }
    private static void Capture(Window window, string file)
    {
        var value = (FrameworkElement)window.Content; value.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(value.ActualWidth), (int)Math.Ceiling(value.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(value);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(file); encoder.Save(stream);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (object child in LogicalTreeHelper.GetChildren(root)) if (child is DependencyObject node) foreach (var value in Descendants(node)) yield return value;
        if (root is Visual or System.Windows.Media.Media3D.Visual3D)
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var value in Descendants(VisualTreeHelper.GetChild(root, i))) yield return value;
    }
    private static bool Has(DependencyObject root, string id) => Descendants(root).OfType<FrameworkElement>().Any(value => AutomationProperties.GetAutomationId(value) == id);
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
}
