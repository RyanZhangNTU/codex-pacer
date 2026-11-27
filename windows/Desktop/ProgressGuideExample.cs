using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;

namespace CodexPacer.Windows;

internal sealed class ProgressGuideExample : Border
{
    internal string Text { get; }
    internal Func<string, bool> WriteClipboard { get; set; } = text =>
    {
        try { Clipboard.SetText(text); return true; }
        catch (ExternalException) { return false; }
    };
    internal TimeSpan FeedbackDuration { get; set; } = TimeSpan.FromSeconds(1.5);

    internal ProgressGuideExample(string text, UiText ui, bool focusable = true)
    {
        Text = text;
        CornerRadius = new CornerRadius(8);
        Padding = new Thickness(10);
        SetResourceReference(BackgroundProperty, "SettingsInfoFill");

        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var prompt = new TextBlock { Text = text, FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Left };
        prompt.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        AutomationProperties.SetAutomationId(prompt, "progress_guide.example");
        row.Children.Add(prompt);

        // Hidden labels still take part in layout, so feedback never changes the prompt's width.
        var labels = new Grid();
        var copy = new TextBlock { Text = ui.Text("progress_guide.action.copy"), HorizontalAlignment = HorizontalAlignment.Center };
        var copied = new TextBlock { Text = ui.Text("support.share.copied"), HorizontalAlignment = HorizontalAlignment.Center };
        labels.Children.Add(copy);
        labels.Children.Add(copied);
        var button = new Button { Content = labels, ContentTemplate = null, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(10, 0, 0, 0), Focusable = focusable };
        AutomationProperties.SetAutomationId(button, "progress_guide.example.copy");
        Grid.SetColumn(button, 1);
        row.Children.Add(button);
        Child = row;

        void ShowCopied(bool success)
        {
            copy.Visibility = success ? Visibility.Hidden : Visibility.Visible;
            copied.Visibility = success ? Visibility.Visible : Visibility.Hidden;
            AutomationProperties.SetName(button, success ? copied.Text : copy.Text);
        }
        ShowCopied(false);
        var reset = new DispatcherTimer();
        reset.Tick += (_, _) => { reset.Stop(); ShowCopied(false); };
        button.Click += (_, _) =>
        {
            if (!WriteClipboard(Text)) return;
            ShowCopied(true);
            reset.Stop();
            reset.Interval = FeedbackDuration;
            reset.Start();
        };
        Unloaded += (_, _) => { reset.Stop(); ShowCopied(false); };
    }
}
