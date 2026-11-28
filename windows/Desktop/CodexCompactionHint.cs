using System;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed class CodexCompactionHint : DockPanel
{
    private readonly UiText ui;
    private readonly Button open;
    private readonly TextBlock message = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };

    internal CodexCompactionHint(UiText ui, Action openGuide)
    {
        this.ui = ui;
        Margin = new Thickness(14, 4, 14, 8); Visibility = Visibility.Collapsed;
        open = new Button { Content = ui.Text("codex.hooks.open"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(open, "settings.codex.compaction.open");
        open.Click += (_, _) => openGuide();
        SetDock(open, Dock.Right); Children.Add(open);
        message.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetAutomationId(message, "settings.codex.compaction.hint");
        Children.Add(message);
    }

    internal static bool Shows(CodexHooks? hooks) => hooks is { OptionalPending: > 0, State: "running" or "notRunning" };
    internal void Update(CodexHooks? hooks)
    {
        Visibility = Shows(hooks) ? Visibility.Visible : Visibility.Collapsed;
        if (Visibility != Visibility.Visible) return;
        message.Text = ui.Text("codex.hooks.compaction_hint").Replace("%d", hooks!.OptionalPending!.Value.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
        open.Visibility = hooks.OpensSettings == true ? Visibility.Visible : Visibility.Collapsed;
    }
}
