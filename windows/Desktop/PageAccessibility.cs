using System.Windows;
using System.Windows.Input;

namespace CodexPacer.Windows;

internal static class PageAccessibility
{
    internal static void Retire(UIElement page)
    {
        page.IsEnabled = false; page.IsHitTestVisible = false;
        KeyboardNavigation.SetTabNavigation(page, KeyboardNavigationMode.None);
        if (page.IsKeyboardFocusWithin) Keyboard.ClearFocus();
    }
}
