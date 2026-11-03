using System;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed class GuideWindow : Window
{
    private readonly UiText ui;
    private readonly GuideContent body;
    private readonly GuideCatalog catalog;
    private readonly Grid root = new();
    private readonly StackPanel footer = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(20, 10, 20, 10) };
    private readonly ScrollViewer scroller;
    private readonly bool welcome;
    private readonly bool? darkOverride;
    private readonly ISystemAppearanceSource appearance;
    private readonly bool ownsAppearance;
    private readonly HighContrastScope semanticPaint;
    private bool closed;
    private int step;
    internal FrameworkElement ClientContent => root;
    internal bool IsWelcome => welcome;
    internal GuideWindow(UiText ui, GuideContent body, GuideCatalog catalog, bool? darkOverride = null, ISystemAppearanceSource? appearanceSource = null)
    {
        this.ui = ui; this.body = body; this.catalog = catalog; welcome = catalog.Page == "welcome";
        this.darkOverride = darkOverride;
        appearance = appearanceSource ?? new SystemAppearanceSource(action => Dispatcher.BeginInvoke(action)); ownsAppearance = appearanceSource == null;
        semanticPaint = new(this);
        WindowRendering.Prepare(this); FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        Title = ui.Text(welcome ? "welcome.window_title" : "whats_new.window_title");
        WindowStartupLocation = WindowStartupLocation.CenterScreen; ResizeMode = ResizeMode.NoResize;
        Width = (welcome ? 560 : 460) + 2 * SystemParameters.FixedFrameVerticalBorderWidth; SizeToContent = SizeToContent.Height;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        ApplyAppearance(); SetResourceReference(BackgroundProperty, "SettingsBackground");
        root.SetResourceReference(Panel.BackgroundProperty, "SettingsBackground");
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition()); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new StackPanel { Margin = new Thickness(24, 18, 24, 10) };
        header.Children.Add(new TextBlock { Text = ui.Text(welcome ? "welcome.title" : "whats_new.title"), FontSize = 20, FontWeight = FontWeights.SemiBold });
        header.Children.Add(new TextBlock { Text = welcome ? ui.Text("welcome.subtitle") : catalog.VersionTitle, FontSize = 12, Margin = new Thickness(0, 5, 0, 0), TextWrapping = TextWrapping.Wrap });
        header.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); root.Children.Add(header);
        body.Margin = new Thickness(20, 0, 20, 8);
        scroller = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        GuideContent.Identify(scroller, "guide.highlights", ui.Text(welcome ? "welcome.step.island" : "whats_new.title"));
        Grid.SetRow(scroller, 1); root.Children.Add(scroller); Grid.SetRow(footer, 2); root.Children.Add(footer); Content = root;
        if (welcome) ShowStep(); else { body.Releases(catalog.Releases); AddButton("whats_new.release_notes", "guide.releaseNotes", body.OpenReleaseNotes); AddButton("whats_new.done", "guide.done", Close, true); }
        Loaded += (_, _) => { Fit(); FocusDefault(); };
        DpiChanged += (_, _) => Fit(); LocationChanged += (_, _) => { if (IsLoaded) Fit(); };
        KeyDown += (_, args) => { if (args.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None) { Close(); args.Handled = true; } };
        appearance.Changed += AppearanceChanged;
        IsVisibleChanged += (_, _) => { body.IsEnabled = footer.IsEnabled = IsVisible && !closed; };
        Loaded += (_, _) => ApplyAppearance();
        Closed += (_, _) =>
        {
            closed = true; IsEnabled = false; appearance.Changed -= AppearanceChanged;
            semanticPaint.Dispose(); if (ownsAppearance) appearance.Dispose();
        };
    }
    private void AppearanceChanged() => Dispatcher.InvokeAsync(() => { if (!closed) ApplyAppearance(); });
    protected override AutomationPeer OnCreateAutomationPeer() => new VisibleWindowAutomationPeer(this);
    private void ApplyAppearance()
    {
        var state = appearance.Current; DesktopAppearance.Apply(this, state);
        SettingsPalette.Apply(Resources, darkOverride ?? state.Dark, true, state); semanticPaint.Apply(state);
    }
    private void AddButton(string key, string id, Action action, bool primary = false)
    {
        var button = new Button { Content = ui.Text(key), IsDefault = primary, Margin = new Thickness(8, 0, 0, 0) };
        GuideContent.Identify(button, id, ui.Text(key)); button.Click += (_, _) => action(); footer.Children.Add(button);
    }
    private void ShowStep()
    {
        foreach (UIElement child in footer.Children) PageAccessibility.Retire(child);
        body.WelcomeStep(step); footer.Children.Clear();
        var progress = new TextBlock { Text = catalog.Steps[step], VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        progress.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); GuideContent.Identify(progress, "welcome.progress", progress.Text); footer.Children.Add(progress);
        if (step == 0)
        {
            AddButton("welcome.all_marks", "welcome.allMarks", body.OpenHelp);
            AddButton("welcome.next", "welcome.next", () => { step = 1; ShowStep(); FocusDefault(); }, true);
        }
        else { AddButton("welcome.back", "welcome.back", () => { step = 0; ShowStep(); FocusDefault(); }); AddButton("welcome.done", "guide.done", Close, true); }
        scroller.ScrollToTop();
    }
    private void FocusDefault() { foreach (var item in footer.Children) if (item is Button { IsDefault: true } button) { button.Focus(); break; } }
    private void Fit()
    {
        if (!IsLoaded) return;
        var screen = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(this).Handle);
        double work = screen.WorkingArea.Height / VisualTreeHelper.GetDpi(this).DpiScaleY;
        double chrome = Math.Max(0, ActualHeight - root.ActualHeight);
        double maximum = GuideSession.MaximumNoteHeight(work, chrome);
        if (welcome) root.Height = Math.Min(532, maximum);
        else
        {
            body.Measure(new Size(420, double.PositiveInfinity));
            double natural = body.DesiredSize.Height + root.Children[0].DesiredSize.Height + footer.DesiredSize.Height;
            root.Height = Math.Min(natural, maximum);
        }
    }
}
