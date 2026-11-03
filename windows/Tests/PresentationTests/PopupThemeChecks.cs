using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// The theme's implicit light text also styles tooltip and menu popups. Their
// surface must stay dark enough for it, instead of the light system chrome.
internal static class PopupThemeChecks
{
    internal static void Run()
    {
        var tip = new ToolTip { Content = "Example" };
        Check(tip, "tooltip");
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = "Example" });
        Check(menu, "menu");
        Console.WriteLine("PASS popup theme: tooltip and menu text keep readable contrast on their dark surface");
    }
    private static void Check(Control popup, string name)
    {
        popup.BeginInit(); popup.EndInit();
        popup.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var surface = Descendants(popup).OfType<Border>().FirstOrDefault(value => value.Background is SolidColorBrush);
        var text = Descendants(popup).OfType<TextBlock>().FirstOrDefault(value => value.Text == "Example");
        if (surface?.Background is not SolidColorBrush back || text?.Foreground is not SolidColorBrush ink)
            throw new InvalidOperationException($"The {name} must draw its own surface and text.");
        double ratio = (Luminance(ink.Color) + 0.05) / (Luminance(back.Color) + 0.05);
        if (Math.Max(ratio, 1 / ratio) < 4.5) throw new InvalidOperationException($"The {name} text must contrast with its surface ({ink.Color} on {back.Color}).");
    }
    private static System.Collections.Generic.IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var value in Descendants(child)) yield return value;
        }
    }
    private static double Luminance(Color color)
    {
        static double Channel(byte value) { double c = value / 255.0; return c <= 0.03928 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4); }
        return 0.2126 * Channel(color.R) + 0.7152 * Channel(color.G) + 0.0722 * Channel(color.B);
    }
}
