using System.Windows;
using System.Windows.Automation;

namespace CodexPacer.Windows;

internal static class ScrollAccessibility
{
    public static readonly DependencyProperty ActionProperty = DependencyProperty.RegisterAttached("Action", typeof(string), typeof(ScrollAccessibility), new PropertyMetadata(null, Changed));
    public static string? GetAction(DependencyObject value) => value.GetValue(ActionProperty) as string;
    public static void SetAction(DependencyObject value, string action) => value.SetValue(ActionProperty, action);
    private static void Changed(DependencyObject value, DependencyPropertyChangedEventArgs args)
    {
        if (value is not FrameworkElement element) return;
        element.Loaded -= Loaded;
        if (args.NewValue == null) return;
        element.Loaded += Loaded; Name(element);
    }
    private static void Loaded(object sender, RoutedEventArgs args) => Name((FrameworkElement)sender);
    private static void Name(FrameworkElement element)
    {
        string? action = GetAction(element);
        if (action is not ("pageUp" or "pageDown" or "position")) return;
        var ui = UiText.For(element.Language.IetfLanguageTag.StartsWith("zh", System.StringComparison.OrdinalIgnoreCase));
        AutomationProperties.SetName(element, ui.Text("windows.accessibility.scroll." + action));
    }
}
