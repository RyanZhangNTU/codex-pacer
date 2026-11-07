using System;
using System.Linq;
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
    private readonly DockPanel footer = new() { LastChildFill = false, Margin = new Thickness(20, 12, 20, 12) };
    private readonly StackPanel actions = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel dots = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
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
        Width = (welcome ? 560 : 480) + 2 * SystemParameters.FixedFrameVerticalBorderWidth; SizeToContent = SizeToContent.Height;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        ApplyAppearance(); SetResourceReference(BackgroundProperty, "SettingsBackground");
        root.SetResourceReference(Panel.BackgroundProperty, "SettingsBackground");
        foreach (var height in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto }) root.RowDefinitions.Add(new RowDefinition { Height = height });
        var header = new DockPanel { Margin = welcome ? new Thickness(24, 20, 24, 4) : new Thickness(40, 36, 40, 0) };
        var icon = new DecorativeImage { Width = welcome ? 52 : 72, Height = welcome ? 52 : 72, Margin = new Thickness(0, 0, 14, 0), Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center,
            Source = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) };
        header.Children.Add(icon);
        // What's New reads like the main window: the icon over one large centered title.
        if (!welcome) { DockPanel.SetDock(icon, Dock.Top); icon.Margin = new Thickness(0); icon.HorizontalAlignment = HorizontalAlignment.Center; }
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        string version = catalog.Releases.FirstOrDefault()?.Version ?? "";
        var heading = new TextBlock { Text = welcome ? ui.Text("welcome.title") : ui.Text("main.whats_new.title").Replace("%@", version, StringComparison.Ordinal),
            FontSize = welcome ? 20 : 24, FontWeight = welcome ? FontWeights.SemiBold : FontWeights.Bold, TextWrapping = TextWrapping.Wrap, TextAlignment = welcome ? TextAlignment.Left : TextAlignment.Center };
        if (!welcome) { heading.Margin = new Thickness(0, 8, 0, 0); titles.HorizontalAlignment = HorizontalAlignment.Stretch; }
        heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); titles.Children.Add(heading);
        var subtitle = new TextBlock { Text = welcome ? ui.Text("welcome.subtitle") : catalog.VersionTitle, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), TextWrapping = TextWrapping.Wrap };
        subtitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); if (welcome) titles.Children.Add(subtitle); header.Children.Add(titles); root.Children.Add(header);
        body.Margin = welcome ? new Thickness(20, 0, 20, 18) : new Thickness(40, 26, 40, 8);
        scroller = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        GuideContent.Identify(scroller, "guide.highlights", ui.Text(welcome ? "welcome.step.island" : "whats_new.title"));
        var divider = new Border { Height = 1 }; divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        DockPanel.SetDock(dots, Dock.Left); DockPanel.SetDock(actions, Dock.Right); footer.Children.Add(dots); footer.Children.Add(actions);
        Grid.SetRow(scroller, 1); root.Children.Add(scroller); Grid.SetRow(divider, 2); root.Children.Add(divider); Grid.SetRow(footer, 3); root.Children.Add(footer); Content = root;
        if (welcome) ShowStep();
        else
        {
            body.Releases(catalog.Releases, large: true);
            // One wide Continue, then Release Notes as a quiet link under it, as on the Mac.
            divider.Visibility = Visibility.Collapsed; footer.Margin = new Thickness(40, 6, 40, 22);
            AddButton("whats_new.done", "guide.done", Close, true);
            var done = (Button)actions.Children[0]; done.MinHeight = 34; done.HorizontalAlignment = HorizontalAlignment.Stretch;
            DockPanel.SetDock(actions, Dock.Top); actions.HorizontalAlignment = HorizontalAlignment.Stretch; actions.Orientation = Orientation.Vertical;
            var notes = CreateButton("whats_new.release_notes", "guide.releaseNotes", body.OpenReleaseNotes);
            notes.Style = (Style)FindResource("SettingsLink"); notes.Content = ui.Text("whats_new.release_notes") + " ↗"; notes.FontSize = 12;
            notes.SetResourceReference(ForegroundProperty, "SettingsSecondary"); notes.HorizontalAlignment = HorizontalAlignment.Center; notes.Margin = new Thickness(0, 12, 0, 0);
            actions.Children.Add(notes);
        }
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
        SettingsPalette.Apply(Resources, darkOverride ?? state.Dark, true, state, main: !welcome); semanticPaint.Apply(state);
    }
    private Button CreateButton(string key, string id, Action action, bool primary = false)
    {
        var button = new Button { Content = ui.Text(key), IsDefault = primary, Padding = new Thickness(12, 4, 12, 4) };
        // The default action is the prominent one, as on the Mac guide.
        if (primary) button.Style = (Style)FindResource("SettingsProminentButton");
        GuideContent.Identify(button, id, ui.Text(key)); button.Click += (_, _) => action(); return button;
    }
    private void AddButton(string key, string id, Action action, bool primary = false)
    {
        var button = CreateButton(key, id, action, primary); button.Margin = new Thickness(actions.Children.Count == 0 ? 0 : 10, 0, 0, 0); actions.Children.Add(button);
    }
    private void ShowStep()
    {
        foreach (UIElement child in actions.Children) PageAccessibility.Retire(child);
        body.WelcomeStep(step); actions.Children.Clear(); dots.Children.Clear();
        GuideContent.Identify(scroller, "guide.highlights", catalog.Steps[step]);
        for (int i = 0; i < 2; i++)
        {
            var dot = new System.Windows.Shapes.Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 6, 0), Opacity = i == step ? 0.8 : 0.22 };
            dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "SettingsPrimary"); dots.Children.Add(dot);
        }
        GuideContent.Identify(dots, "welcome.progress", catalog.Steps[step]); System.Windows.Automation.AutomationProperties.SetLiveSetting(dots, System.Windows.Automation.AutomationLiveSetting.Polite);
        if (step == 0)
        {
            AddButton("welcome.all_marks", "welcome.allMarks", body.OpenHelp);
            AddButton("welcome.next", "welcome.next", () => { step = 1; ShowStep(); FocusDefault(); }, true);
        }
        else { AddButton("welcome.back", "welcome.back", () => { step = 0; ShowStep(); FocusDefault(); }); AddButton("welcome.done", "guide.done", Close, true); }
        scroller.ScrollToTop();
    }
    private void FocusDefault() { foreach (var item in actions.Children) if (item is Button { IsDefault: true } button) { button.Focus(); break; } }
    private void Fit()
    {
        if (!IsLoaded) return;
        var screen = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(this).Handle);
        double work = screen.WorkingArea.Height / VisualTreeHelper.GetDpi(this).DpiScaleY;
        double chrome = Math.Max(0, ActualHeight - root.ActualHeight);
        double maximum = GuideSession.MaximumNoteHeight(work, chrome);
        // Windows text runs slightly taller than the Mac guide's 532 points.
        if (welcome) root.Height = Math.Min(560, maximum);
        else
        {
            body.Measure(new Size(400, double.PositiveInfinity));
            double natural = body.DesiredSize.Height + body.Margin.Top + body.Margin.Bottom + root.Children[0].DesiredSize.Height + 1 + footer.DesiredSize.Height;
            root.Height = Math.Min(natural, maximum);
        }
    }
}
