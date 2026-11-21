using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// The small floating guide beside Codex while the user allows Pacer's hooks:
/// the clicks on Codex's Hooks page, drawn as they look there, and the shorter
/// way from a chat. Settings' Open Codex shows it. It follows the hooks' state
/// in the engine's snapshot, which the engine refreshes within seconds of the
/// approval; says it's done for eight seconds once they are allowed, and
/// closes then, on Close or after ten minutes. It never reads Codex's window.
internal sealed class CodexHooksGuideFloat : GuideFloatWindow
{
    /// The plugin's name on Codex's Hooks page (Core's `CodexHookPlugin.displayName`).
    internal const string PluginName = "Codex Pacer";
    /// Pacer registers this many hooks (Core's `CodexHookEvent.Kind`).
    internal const int HookCount = 7;
    private static readonly TimeSpan DoneShown = TimeSpan.FromSeconds(8), Lifetime = TimeSpan.FromMinutes(10);

    private static CodexHooksGuideFloat? current;
    internal static CodexHooksGuideFloat? Current => current;

    private readonly Func<CodexHooks?> hooks;
    private readonly Func<bool> disconnected;
    private readonly DispatcherTimer timer;
    private readonly DateTime openedAt = DateTime.UtcNow;
    private DateTime? doneSince;
    private readonly TextBlock title, alternative;
    private readonly StackPanel steps, done;
    private readonly Border art;
    private string key = "";

    /// Shows the guide beside Codex, replacing any other guide.
    internal static void Open(EngineClient client, UiText ui, ResourceDictionary resources, System.Drawing.Rectangle area)
    {
        HarnessGuideFloat.Current?.Close();
        current?.Close();
        var shown = new CodexHooksGuideFloat(() => client.LatestSnapshot?.CodexHooks, () => client.IsConnectionClosed, ui, resources, area);
        shown.Closed += (_, _) => { shown.timer.Stop(); if (current == shown) current = null; };
        current = shown;
        shown.timer.Start();
        shown.Follow();
    }

    /// <param name="hooks">The hooks' state in the engine's latest snapshot.</param>
    /// <param name="disconnected">Whether the engine connection closed.</param>
    internal CodexHooksGuideFloat(Func<CodexHooks?> hooks, Func<bool> disconnected, UiText ui, ResourceDictionary resources, System.Drawing.Rectangle area)
        : base(ui, resources, area, "codex_hooks_guide")
    {
        this.hooks = hooks; this.disconnected = disconnected;
        Header.Text = "Pacer · Codex";
        title = new TextBlock { FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Text = ui.Text("codex.hooks.guide.title") };
        title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        AutomationProperties.SetAutomationId(title, "codex_hooks_guide.title");
        // The float never takes focus, so a screen reader hears when it is done.
        AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        steps = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        string[] lines = [ui.Text("codex.hooks.guide.step_hooks"), ui.Text("codex.hooks.guide.step_plugin").Replace("%@", PluginName, StringComparison.Ordinal),
            ui.Text("codex.hooks.guide.step_trust")];
        for (int index = 0; index < lines.Length; index++)
        {
            var row = new DockPanel { Margin = new Thickness(0, index == 0 ? 0 : 6, 0, 0) };
            var badge = Badge(index + 1); badge.Margin = new Thickness(0, 1, 8, 0); badge.VerticalAlignment = VerticalAlignment.Top;
            row.Children.Add(badge);
            var text = new TextBlock { Text = lines[index], FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
            text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
            row.Children.Add(text);
            steps.Children.Add(row);
        }
        AutomationProperties.SetAutomationId(steps, "codex_hooks_guide.steps");
        AutomationProperties.SetName(steps, string.Join(" ", lines));
        art = new Border { Margin = new Thickness(0, 12, 0, 0) };
        alternative = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0), Text = ui.Text("codex.hooks.guide.alternative") };
        alternative.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        done = new StackPanel { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
        var check = new IconGlyph { Symbol = "checkmark.circle.fill", Width = 18, Height = 18, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        check.SetResourceReference(IconGlyph.InkProperty, "SettingsSuccess");
        var doneText = new TextBlock { Text = ui.Text("codex.hooks.guide.done"), FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        doneText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        AutomationProperties.SetAutomationId(doneText, "codex_hooks_guide.done");
        AutomationProperties.SetLiveSetting(doneText, AutomationLiveSetting.Polite);
        done.Children.Add(check); done.Children.Add(doneText);
        Body.Children.Add(title); Body.Children.Add(steps); Body.Children.Add(art); Body.Children.Add(alternative); Body.Children.Add(done);
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => { if (current == this) Follow(); else timer.Stop(); };
    }

    /// Where the guide stands for the hooks' state: allowed hooks are done; a
    /// state the guide doesn't describe closes it, and Settings says what to do.
    internal static string Phase(string? state) => state switch
    {
        "running" or "notRunning" => "done",
        "off" or "needsCodexUpdate" or "installFailed" => "gone",
        _ => "steps"
    };

    /// Shows the steps, says it's done, or closes, for the hooks' current state.
    internal void Follow()
    {
        if (disconnected() || DateTime.UtcNow - openedAt > Lifetime) { Close(); return; }
        var state = hooks();
        switch (Phase(state?.State))
        {
            case "gone": Close(); return;
            case "done":
                doneSince ??= DateTime.UtcNow;
                if (DateTime.UtcNow - doneSince.Value >= DoneShown) { Close(); return; }
                Display("done");
                break;
            default:
                doneSince = null;
                Display("steps:" + (state?.State == "needsApproval" && state.Pending is int pending ? pending : HookCount));
                break;
        }
    }

    private void Display(string state)
    {
        if (state != key)
        {
            bool finished = state == "done";
            key = state;
            title.Visibility = steps.Visibility = art.Visibility = alternative.Visibility = finished ? Visibility.Collapsed : Visibility.Visible;
            done.Visibility = finished ? Visibility.Visible : Visibility.Collapsed;
            if (!finished) art.Child = Picture(int.Parse(state["steps:".Length..], System.Globalization.CultureInfo.InvariantCulture));
            if (finished && Presented && done.Children[1] is TextBlock line)
                UIElementAutomationPeer.FromElement(line)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
        ShowFloat();
    }

    /// A step's number, as the picture marks the place to click.
    private static Border Badge(int number)
    {
        var badge = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8),
            Child = new TextBlock { Text = number.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 10, FontWeight = FontWeights.Bold,
                Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
        badge.SetResourceReference(Border.BackgroundProperty, "SettingsAccent");
        return badge;
    }

    /// A drawing of Codex's Hooks settings: Hooks in its sidebar, Pacer's plugin
    /// under From Plugins with the hooks waiting for review, and Trust all inside
    /// a ring. Numbers mark the steps. The steps already say what to do.
    private DecorativeBorder Picture(int pending)
    {
        static Border Placeholder(double width)
        {
            var bar = new Border { Width = width, Height = 7, CornerRadius = new CornerRadius(3.5), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 3.5, 0, 3.5) };
            bar.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
            return bar;
        }
        TextBlock Text(string value, double size, bool strong = false, string brush = "SettingsPrimary")
        {
            var text = new TextBlock { Text = value, FontSize = size, FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            text.SetResourceReference(TextBlock.ForegroundProperty, brush);
            return text;
        }
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(104) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        var sidebar = new StackPanel { Margin = new Thickness(10) };
        sidebar.Children.Add(Placeholder(46)); sidebar.Children.Add(Placeholder(58));
        var hooks = new DockPanel { Height = 24, Margin = new Thickness(0, 3, 0, 3) };
        var first = Badge(1); first.Margin = new Thickness(4, 0, 0, 0); DockPanel.SetDock(first, Dock.Right); hooks.Children.Add(first);
        hooks.Children.Add(Text(ui.Text("codex.hooks.guide.picture.hooks"), 11, strong: true));
        var selected = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(7, 0, 7, 0), Child = hooks };
        selected.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        sidebar.Children.Add(selected); sidebar.Children.Add(Placeholder(40));
        grid.Children.Add(sidebar);

        var divider = new System.Windows.Shapes.Rectangle { Width = 1 }; divider.SetResourceReference(Shape.FillProperty, "SettingsCardBorder");
        Grid.SetColumn(divider, 1); grid.Children.Add(divider);

        var page = new StackPanel { Margin = new Thickness(10) };
        page.Children.Add(Text(ui.Text("codex.hooks.guide.picture.plugins"), 10.5, brush: "SettingsSecondary"));
        var plugin = new DockPanel { Height = 38 };
        var second = Badge(2); second.Margin = new Thickness(6, 0, 0, 0); DockPanel.SetDock(second, Dock.Right); plugin.Children.Add(second);
        var review = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var warning = new IconGlyph { Symbol = "exclamationmark.triangle", Width = 11, Height = 11, Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center };
        warning.SetResourceReference(IconGlyph.InkProperty, "SettingsWarning");
        review.Children.Add(warning);
        review.Children.Add(Text(ui.Text(pending == 1 ? "codex.hooks.guide.picture.review_one" : "codex.hooks.guide.picture.review")
            .Replace("%ld", pending.ToString(System.Globalization.CultureInfo.CurrentCulture), StringComparison.Ordinal), 10, brush: "SettingsWarning"));
        DockPanel.SetDock(review, Dock.Right); plugin.Children.Add(review);
        var icon = new DecorativeImage { Width = 18, Height = 18, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center,
            Source = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) };
        plugin.Children.Add(icon);
        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) };
        name.Children.Add(Text(PluginName, 11.5, strong: true));
        name.Children.Add(Text(ui.Text("codex.hooks.guide.picture.count").Replace("%ld", HookCount.ToString(System.Globalization.CultureInfo.CurrentCulture), StringComparison.Ordinal), 10, brush: "SettingsSecondary"));
        plugin.Children.Add(name);
        var row = new Border { CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1), Padding = new Thickness(8, 0, 8, 0), Margin = new Thickness(0, 8, 0, 8), Child = plugin };
        row.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); row.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        page.Children.Add(row);
        var trustRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var third = Badge(3); third.Margin = new Thickness(0, 0, 6, 0); third.VerticalAlignment = VerticalAlignment.Center; trustRow.Children.Add(third);
        var trust = new Border { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), Padding = new Thickness(12, 0, 12, 0), Height = 24,
            Child = Text(ui.Text("codex.hooks.guide.picture.trust_all"), 11, strong: true) };
        trust.SetResourceReference(Border.BorderBrushProperty, "SettingsSecondary");
        var ring = new Border { BorderThickness = new Thickness(2.5), CornerRadius = new CornerRadius(9), Padding = new Thickness(2), Child = trust };
        ring.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        trustRow.Children.Add(ring);
        page.Children.Add(trustRow);
        Grid.SetColumn(page, 2); grid.Children.Add(page);

        var frame = new DecorativeBorder { CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1), Child = grid };
        frame.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill"); frame.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        return frame;
    }
}
