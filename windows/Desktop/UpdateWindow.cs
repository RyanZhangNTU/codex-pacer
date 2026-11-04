using System;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// Pacer's own update window, in the Settings style: the offer with its signed
/// notes, the download with real progress, and the handoff to the installer.
internal sealed class UpdateWindow : Window, IWindowsUpdatePresenter
{
    internal enum Stage { Checking, Offer, Downloading, Verifying, Ready, UpToDate, Failed }
    private readonly UiText ui;
    private readonly WindowsUpdateService service;
    private readonly string currentVersion;
    private readonly bool? darkOverride;
    private readonly ISystemAppearanceSource appearance;
    private readonly bool ownsAppearance;
    private readonly HighContrastScope semanticPaint;
    private readonly TextBlock heading = new() { FontSize = 18, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock detail = new() { FontSize = 13, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap };
    private readonly ContentControl body = new() { Focusable = false, Margin = new Thickness(24, 0, 24, 18) };
    private readonly DockPanel footer = new() { LastChildFill = false, Margin = new Thickness(20, 12, 20, 12) };
    private readonly ProgressBar progress = new();
    private readonly TextBlock progressText = new() { FontSize = 12, Margin = new Thickness(0, 8, 0, 0) };
    private CancellationTokenSource? download;
    private VerifiedDownload? verified;
    private bool closed, handedOff;
    internal Stage Current { get; private set; }
    internal UpdateWindow(UiText ui, WindowsUpdateService service, string currentVersion, bool? darkOverride = null, ISystemAppearanceSource? appearanceSource = null)
    {
        this.ui = ui; this.service = service; this.currentVersion = currentVersion; this.darkOverride = darkOverride;
        appearance = appearanceSource ?? new SystemAppearanceSource(action => Dispatcher.BeginInvoke(action)); ownsAppearance = appearanceSource == null;
        semanticPaint = new(this);
        WindowRendering.Prepare(this); FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        Title = ui.Text("windows.updates.window_title"); WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize; Width = 520 + 2 * SystemParameters.FixedFrameVerticalBorderWidth; SizeToContent = SizeToContent.Height;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        ApplyAppearance(); SetResourceReference(BackgroundProperty, "SettingsBackground");
        var root = new Grid(); root.SetResourceReference(Panel.BackgroundProperty, "SettingsBackground");
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, GridLength.Auto }) root.RowDefinitions.Add(new RowDefinition { Height = height });
        var header = new DockPanel { Margin = new Thickness(24, 20, 24, 14) };
        header.Children.Add(new DecorativeImage { Width = 52, Height = 52, Margin = new Thickness(0, 0, 14, 0), Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Top,
            Source = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        titles.Children.Add(heading); titles.Children.Add(detail); header.Children.Add(titles); root.Children.Add(header);
        GuideContent.Identify(heading, "update.title", ""); GuideContent.Identify(detail, "update.status", "");
        AutomationProperties.SetLiveSetting(detail, AutomationLiveSetting.Polite);
        progress.Style = (Style)FindResource("SettingsProgressBar");
        progressText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        GuideContent.Identify(progress, "update.progress", ui.Text("windows.updates.downloading_title"));
        AutomationProperties.SetLiveSetting(progressText, AutomationLiveSetting.Polite);
        Grid.SetRow(body, 1); root.Children.Add(body);
        var divider = new Border { Height = 1 }; divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        Grid.SetRow(divider, 2); root.Children.Add(divider); Grid.SetRow(footer, 3); root.Children.Add(footer);
        Content = root;
        KeyDown += (_, args) => { if (args.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None) { Close(); args.Handled = true; } };
        appearance.Changed += AppearanceChanged;
        Loaded += (_, _) => { ApplyAppearance(); FocusDefault(); };
        Closed += (_, _) =>
        {
            closed = true; download?.Cancel(); appearance.Changed -= AppearanceChanged;
            semanticPaint.Dispose(); if (ownsAppearance) appearance.Dispose();
            if (!handedOff) service.Dismiss();
        };
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new VisibleWindowAutomationPeer(this);
    private void AppearanceChanged() => Dispatcher.InvokeAsync(() => { if (!closed) ApplyAppearance(); });
    private void ApplyAppearance()
    {
        var state = appearance.Current; DesktopAppearance.Apply(this, state);
        SettingsPalette.Apply(Resources, darkOverride ?? state.Dark, true, state); semanticPaint.Apply(state);
    }
    public void Checking() => Show(Stage.Checking, ui.Text("updates.checking"), "", null);
    public void UpToDate() => Show(Stage.UpToDate, ui.Text("windows.updates.up_to_date_title"),
        Format("windows.updates.up_to_date_detail", currentVersion), null, ("windows.updates.ok", "update.ok", Close, true));
    public void Failed() => Show(Stage.Failed, ui.Text("windows.updates.error_title"), ui.Text("windows.updates.error_detail"), null,
        ("windows.updates.close", "update.close", Close, false), ("windows.updates.try_again", "update.retry", Retry, true));
    public void Offer(WindowsUpdatePackage package, bool manual)
    {
        string size = Format(package.Incremental ? "windows.updates.download_size_incremental" : "windows.updates.download_size", Size(package.Length));
        Show(Stage.Offer, ui.Text("windows.updates.new_version_title"), Format("windows.updates.new_version_detail", package.Version, currentVersion) + "\n" + size, NotesView(ui, package.Notes),
            ("windows.updates.later", "update.later", Close, false), ("windows.updates.install", "update.install", Download, true));
        var skip = CreateButton("windows.updates.skip", "update.skip", () => { handedOff = true; service.Skip(); Close(); }, false);
        DockPanel.SetDock(skip, Dock.Left); footer.Children.Insert(0, skip);
    }
    // The open window keeps the service busy; Try Again ends that operation
    // and starts a manual check that reports back to this window.
    private void Retry() { if (closed) return; service.Dismiss(); _ = service.CheckAsync(); }
    private async void Download()
    {
        if (closed || service.CurrentOffer is not { } package) return;
        download = new CancellationTokenSource();
        BeginDownload(package);
        try
        {
            verified = await service.DownloadAsync(new Progress<UpdateProgress>(Report), download.Token);
            if (!closed) ShowReady(package);
        }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error))
        {
            if (closed) return;
            if (service.CurrentOffer is { } changed && changed != package) Offer(changed, true);
            else Failed();
        }
    }
    internal void BeginDownload(WindowsUpdatePackage package)
    {
        progress.Value = 0; progressText.Text = Format("windows.updates.progress", Size(0), Size(package.Length), Percent(0));
        var panel = new StackPanel(); panel.Children.Add(progress); panel.Children.Add(progressText);
        Show(Stage.Downloading, ui.Text("windows.updates.downloading_title"), Format("windows.updates.new_version_detail", package.Version, currentVersion), panel,
            ("common.cancel", "update.cancel", Close, false));
    }
    internal void Report(UpdateProgress value)
    {
        if (closed || Current != Stage.Downloading || value.Total <= 0) return;
        double fraction = Math.Clamp((double)value.Received / value.Total, 0, 1);
        progress.Value = fraction;
        progressText.Text = Format("windows.updates.progress", Size(value.Received), Size(value.Total), Percent(fraction));
        if (value.Received == value.Total) Show(Stage.Verifying, ui.Text("windows.updates.verifying"), "", null, ("common.cancel", "update.cancel", Close, false));
    }
    internal void ShowReady(WindowsUpdatePackage package) => Show(Stage.Ready, ui.Text("windows.updates.ready_title"), Format("windows.updates.ready_detail", package.Version), null,
        ("windows.updates.later", "update.later", Close, false), ("windows.updates.install_relaunch", "update.relaunch", Install, true));
    private void Install()
    {
        if (closed || verified == null) return;
        try { if (service.Install(verified)) { handedOff = true; Close(); } else Failed(); }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { Failed(); }
    }
    private void Show(Stage stage, string title, string text, UIElement? content, params (string Key, string Id, Action Action, bool Primary)[] buttons)
    {
        if (closed) return;
        Current = stage; heading.Text = title; detail.Text = text; detail.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(heading, title); AutomationProperties.SetName(detail, text);
        if (!ReferenceEquals(body.Content, content) && !(stage == Stage.Verifying && body.Content is StackPanel)) body.Content = content;
        body.Visibility = body.Content == null ? Visibility.Collapsed : Visibility.Visible;
        foreach (UIElement child in footer.Children) PageAccessibility.Retire(child);
        footer.Children.Clear();
        var actions = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(actions, Dock.Right); footer.Children.Add(actions);
        foreach (var (key, id, action, primary) in buttons)
        {
            var button = CreateButton(key, id, action, primary); button.Margin = new Thickness(actions.Children.Count == 0 ? 0 : 10, 0, 0, 0);
            actions.Children.Add(button);
        }
        if (IsLoaded) FocusDefault();
    }
    private Button CreateButton(string key, string id, Action action, bool primary)
    {
        var button = new Button { Content = ui.Text(key), IsDefault = primary, Padding = new Thickness(12, 4, 12, 4) };
        if (primary) button.Style = (Style)FindResource("SettingsProminentButton");
        GuideContent.Identify(button, id, ui.Text(key)); button.Click += (_, _) => action(); return button;
    }
    private void FocusDefault() { foreach (var item in LogicalTreeHelper.GetChildren(footer)) if (item is StackPanel row) foreach (var child in row.Children) if (child is Button { IsDefault: true } button) { button.Focus(); return; } }
    private string Format(string key, params object[] values) => string.Format(CultureInfo.CurrentCulture, ui.Text(key), values);
    private static string Size(long bytes) => (bytes / 1048576.0).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
    private static string Percent(double fraction) => (fraction * 100).ToString("0", CultureInfo.CurrentCulture) + "%";
    /// The signed notes as a selectable document in the Settings palette.
    internal static FrameworkElement NotesView(UiText ui, string markdown)
    {
        var document = new FlowDocument { PagePadding = new Thickness(14, 10, 14, 10), FontFamily = PacerFonts.Interface, FontSize = 13 };
        document.SetResourceReference(FlowDocument.ForegroundProperty, "SettingsPrimary");
        var blocks = ReleaseNotesMarkdown.Parse(markdown);
        if (blocks.Count == 0) document.Blocks.Add(new Paragraph(new Run(ui.Text("windows.updates.notes_empty"))));
        List? list = null;
        foreach (var block in blocks)
        {
            if (block.Kind is NoteBlockKind.Bullet or NoteBlockKind.Numbered)
            {
                var marker = block.Kind == NoteBlockKind.Bullet ? TextMarkerStyle.Disc : TextMarkerStyle.Decimal;
                if (list == null || list.MarkerStyle != marker) { list = new List { MarkerStyle = marker, Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(18, 0, 0, 0) }; document.Blocks.Add(list); }
                var item = new Paragraph { Margin = new Thickness(0, 0, 0, 4) }; Inlines(item.Inlines, block.Spans); list.ListItems.Add(new ListItem(item));
                continue;
            }
            list = null;
            var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 8) };
            if (block.Kind == NoteBlockKind.Heading) { paragraph.FontWeight = FontWeights.SemiBold; paragraph.FontSize = block.Level == 1 ? 16 : 14; paragraph.Margin = new Thickness(0, 4, 0, 6); }
            Inlines(paragraph.Inlines, block.Spans); document.Blocks.Add(paragraph);
        }
        var viewer = new FlowDocumentScrollViewer { Document = document, MaxHeight = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, IsToolBarVisible = false, Focusable = true };
        GuideContent.Identify(viewer, "update.notes", ui.Text("whats_new.release_notes"));
        var tile = new Border { Child = viewer, CornerRadius = new CornerRadius(8) }; tile.SetResourceReference(Border.BackgroundProperty, "SettingsTile");
        return tile;
    }
    private static void Inlines(InlineCollection target, System.Collections.Generic.IReadOnlyList<NoteSpan> spans)
    {
        foreach (var span in spans)
        {
            Inline inline = span.Kind switch
            {
                NoteSpanKind.Strong => new Bold(new Run(span.Text)),
                NoteSpanKind.Code => new Run(span.Text) { FontFamily = new FontFamily("Consolas") },
                NoteSpanKind.Link when span.Link != null => LinkTo(span),
                _ => new Run(span.Text)
            };
            target.Add(inline);
        }
    }
    private static Hyperlink LinkTo(NoteSpan span)
    {
        var link = new Hyperlink(new Run(span.Text)) { NavigateUri = span.Link };
        link.SetResourceReference(TextElement.ForegroundProperty, "SettingsAccent");
        link.RequestNavigate += (_, args) =>
        {
            args.Handled = true;
            if (ReleaseNotesMarkdown.Allowed(args.Uri.AbsoluteUri) is not { } target) return;
            try { using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target.AbsoluteUri) { UseShellExecute = true }); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        };
        return link;
    }
}
