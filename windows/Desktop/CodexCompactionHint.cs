using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed class CodexCompactionHint : DockPanel
{
    internal CodexCompactionHint(UiText ui, Func<Task> updateHooks)
    {
        Margin = new Thickness(14, 4, 14, 8); Visibility = Visibility.Collapsed;
        var update = new Button { Content = ui.Text("codex.hooks.update"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(update, "settings.codex.hooks.update");
        update.Click += async (_, _) => await updateHooks();
        SetDock(update, Dock.Right); Children.Add(update);
        var message = new TextBlock { Text = ui.Text("codex.hooks.update_hint"), FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetAutomationId(message, "settings.codex.compaction.hint");
        Children.Add(message);
    }

    internal static bool Shows(CodexHooks? hooks) => hooks?.UpdateAvailable == true;
    internal void Update(CodexHooks? hooks) => Visibility = Shows(hooks) ? Visibility.Visible : Visibility.Collapsed;
}
