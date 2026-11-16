using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexPacer.Windows;

/// What to do when Pacer cannot check for or download an update, most often
/// because the network cannot reach GitHub: try again, or get the full
/// installer from GitHub, from a download site that needs no GitHub, or from
/// the QQ group, and install it over this version. Help &amp; Updates shows all
/// of it; the update window shows the ways under its own heading.
internal sealed class UpdateRecoveryView : StackPanel
{
    internal enum Kind { Check, Download }
    internal static readonly Uri LatestRelease = new("https://github.com/RyanZhangNTU/codex-pacer/releases/latest");
    internal static readonly Uri DownloadMirror = new("https://pacer.bhgmz.com/");
    internal const string QqGroup = "1131553244";
    private readonly UiText ui;
    private readonly Func<Uri, bool> open;
    private readonly Action<string> copy;
    private readonly TextBlock title = Line(13.5, FontWeights.SemiBold, "SettingsPrimary");
    private readonly TextBlock detail = Line(12, FontWeights.Normal, "SettingsSecondary");
    private readonly TextBlock lastCheck = Line(11.5, FontWeights.Normal, "SettingsSecondary");
    private readonly TextBlock githubDetail = Line(11.5, FontWeights.Normal, "SettingsSecondary");
    private readonly TextBlock issue = Line(11.5, FontWeights.Normal, "SettingsWarning");
    private readonly Button retry;
    private Action? retryAction;
    private int copyRevision;
    /// The QQ group's code, while its popup can open.
    internal Popup? CodePopup { get; private set; }

    /// `full` adds the heading, its detail and Try Again; the update window
    /// keeps those in its own header and footer.
    internal UpdateRecoveryView(UiText ui, Func<Uri, bool>? open, Action<string>? copy, bool full)
    {
        this.ui = ui; this.open = open ?? DefaultOpen; this.copy = copy ?? Clipboard.SetText;
        retry = new Button { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(12, 0, 0, 0) };
        retry.SetResourceReference(StyleProperty, "SettingsProminentButton");
        GuideContent.Identify(retry, "update.recovery.retry", ""); retry.Click += (_, _) => retryAction?.Invoke();
        if (full)
        {
            var head = new Grid { Margin = new Thickness(0, 0, 0, 10) };
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); head.ColumnDefinitions.Add(new ColumnDefinition()); head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var tile = GuideArt.Tile("network.slash", Color.FromRgb(0xF2, 0xA5, 0x3A), 30); tile.Margin = new Thickness(0, 1, 10, 0); tile.VerticalAlignment = VerticalAlignment.Top; head.Children.Add(tile);
            var words = new StackPanel();
            words.Children.Add(title); detail.Margin = new Thickness(0, 3, 0, 0); words.Children.Add(detail);
            lastCheck.Margin = new Thickness(0, 4, 0, 0); words.Children.Add(lastCheck);
            Grid.SetColumn(words, 1); head.Children.Add(words);
            Grid.SetColumn(retry, 2); head.Children.Add(retry);
            Children.Add(head);
            GuideContent.Identify(title, "update.recovery.title", ""); GuideContent.Identify(detail, "update.recovery.detail", "");
            AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        }
        var ways = new StackPanel();
        var github = Button(ui.Text("update.route.open"), "update.route.github", () => Open(LatestRelease)); WithArrow(github);
        ways.Children.Add(Row("link", Color.FromRgb(0x3A, 0x3F, 0x47), ui.Text("update.route.github"), githubDetail, github));
        ways.Children.Add(Separator());
        var mirror = Button(ui.Text("update.route.open"), "update.route.mirror", () => Open(DownloadMirror)); WithArrow(mirror);
        ways.Children.Add(Row("server.rack", Color.FromRgb(0x2F, 0x80, 0xED), ui.Text("update.route.mirror"), Line(11.5, FontWeights.Normal, "SettingsSecondary", ui.Text("update.route.mirror_detail")), mirror));
        ways.Children.Add(Separator());
        Button? copyButton = null;
        copyButton = Button(ui.Text("support.qq.copy"), "update.route.qq.copy", () => _ = Copy(copyButton!));
        var qqActions = new StackPanel { Orientation = Orientation.Horizontal };
        qqActions.Children.Add(copyButton);
        if (QqCodeImage() is string image)
        {
            Popup? popup = null;
            var show = Button(ui.Text("support.qq.code"), "update.route.qq.code", () => { if (popup != null) popup.IsOpen = !popup.IsOpen; });
            show.Margin = new Thickness(6, 0, 0, 0);
            var content = CodeCard(image, ui.Text("support.qq.hint"));
            popup = new Popup { PlacementTarget = show, Placement = PlacementMode.Bottom, StaysOpen = false, Child = content, AllowsTransparency = true };
            content.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { popup.IsOpen = false; show.Focus(); args.Handled = true; } };
            WindowRendering.Prepare(popup); popup.Opened += (_, _) => content.Focus();
            CodePopup = popup; qqActions.Children.Add(show);
        }
        ways.Children.Add(Row("person.2", Color.FromRgb(0x12, 0xB7, 0xF5), ui.Text("update.route.qq").Replace("%@", QqGroup, StringComparison.Ordinal),
            Line(11.5, FontWeights.Normal, "SettingsSecondary", ui.Text("update.route.qq_detail")), qqActions));
        var list = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = ways };
        list.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        GuideContent.Identify(list, "update.recovery.ways", ui.Text("update.route.github"));
        Children.Add(list);
        var footer = Line(11.5, FontWeights.Normal, "SettingsSecondary", ui.Text("update.failure.install_windows")); footer.Margin = new Thickness(0, 8, 0, 0);
        Children.Add(footer);
        issue.Visibility = Visibility.Collapsed; issue.Margin = new Thickness(0, 4, 0, 0); Children.Add(issue);
    }

    /// Fills the words for a failed check or a failed download of `version`.
    internal void Show(Kind kind, string installed, string? version, DateTimeOffset? lastSuccess, Action? tryAgain)
    {
        bool check = kind == Kind.Check || version == null;
        title.Text = check ? ui.Text("update.failure.check_title") : ui.Text("update.failure.download_title").Replace("%@", version!, StringComparison.Ordinal);
        detail.Text = check ? ui.Text("update.failure.check_detail").Replace("%@", installed, StringComparison.Ordinal)
            : ui.Text("update.failure.download_detail").Replace("%@", version!, StringComparison.Ordinal);
        // Without a recorded success the line stays out, as on the Mac, rather than claim there never was one.
        lastCheck.Text = check && lastSuccess is { } last
            ? ui.Text("update.failure.last_success").Replace("%@", last.ToLocalTime().ToString("g", System.Globalization.CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US")), StringComparison.Ordinal)
            : "";
        lastCheck.Visibility = lastCheck.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        githubDetail.Text = check ? ui.Text("update.route.github_latest").Replace("%@", InstallerSuffix(), StringComparison.Ordinal)
            : ui.Text("update.route.github_file").Replace("%@", InstallerName(version!), StringComparison.Ordinal);
        retryText = ui.Text(check ? "update.failure.retry_check" : "update.failure.retry_download");
        retry.Content = retryText; AutomationProperties.SetName(retry, retryText);
        retryAction = tryAgain; retry.Visibility = tryAgain == null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(title, title.Text); AutomationProperties.SetName(detail, detail.Text);
        AutomationProperties.SetName(this, title.Text);
        issue.Visibility = Visibility.Collapsed;
    }
    internal bool RetryEnabled { get => retry.IsEnabled; set => retry.IsEnabled = value; }
    private string retryText = "";
    /// While a check runs, its button says so and waits.
    internal bool Checking
    {
        set
        {
            string text = value ? ui.Text("updates.checking") : retryText;
            if (text.Length == 0) return;
            retry.Content = text; AutomationProperties.SetName(retry, text);
            if (value) retry.IsEnabled = false;
        }
    }

    /// The installer for this computer's architecture, as each GitHub Release names it.
    internal static string InstallerSuffix() => "windows-" + Architecture() + "-setup.exe";
    internal static string InstallerName(string version) => "Codex-Pacer-" + version + "-" + InstallerSuffix();
    private static string Architecture() => RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
    /// The QQ group's code ships in Core's resources, next to the app or beside the engine.
    internal static string? QqCodeImage()
    {
        foreach (string folder in new[] { AppContext.BaseDirectory, Path.Combine(AppContext.BaseDirectory, "Engine") })
        {
            string path = Path.Combine(folder, "CodexPacerPortable_PacerCore.resources", "support-qq-group.png");
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private void Open(Uri uri)
    {
        issue.Visibility = Visibility.Collapsed;
        if (!open(uri)) { issue.Text = ui.Text("windows.pages.open_failed"); issue.Visibility = Visibility.Visible; }
    }
    private async Task Copy(Button button)
    {
        try
        {
            copy(QqGroup); int revision = ++copyRevision;
            button.Content = ui.Text("support.share.copied"); AutomationProperties.SetName(button, ui.Text("support.share.copied"));
            await Task.Delay(TimeSpan.FromSeconds(2));
            if (IsLoaded && revision == copyRevision) { button.Content = ui.Text("support.qq.copy"); AutomationProperties.SetName(button, ui.Text("support.qq.copy")); }
        }
        catch (COMException) { issue.Text = ui.Text("windows.pages.copy_failed"); issue.Visibility = Visibility.Visible; }
    }
    private static bool DefaultOpen(Uri uri)
    {
        try { using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return process != null; }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
    private static TextBlock Line(double size, FontWeight weight, string brush, string text = "")
    {
        var line = new TextBlock { Text = text, FontSize = size, FontWeight = weight, TextWrapping = TextWrapping.Wrap };
        line.SetResourceReference(TextBlock.ForegroundProperty, brush); return line;
    }
    private static Button Button(string text, string id, Action action)
    {
        var button = new Button { Content = text, FontSize = 12, Padding = new Thickness(10, 3, 10, 3), VerticalAlignment = VerticalAlignment.Center };
        GuideContent.Identify(button, id, text); button.Click += (_, _) => action(); return button;
    }
    private static void WithArrow(Button button)
    {
        string text = (string)button.Content;
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        var arrow = new IconGlyph { Symbol = "arrow.up.right", Width = 10, Height = 10, Margin = new Thickness(5, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        arrow.SetBinding(IconGlyph.InkProperty, new System.Windows.Data.Binding(nameof(Control.Foreground)) { Source = button });
        // The Settings button template draws text content; a panel replaces that template.
        content.Children.Add(arrow); button.ContentTemplate = null; button.Content = content;
    }
    private static Grid Row(string symbol, Color tint, string heading, TextBlock body, FrameworkElement action)
    {
        var row = new Grid { Margin = new Thickness(10, 8, 10, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = GuideArt.Tile(symbol, tint, 26); tile.Margin = new Thickness(0, 0, 10, 0); tile.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(tile);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Line(13, FontWeights.Medium, "SettingsPrimary", heading)); body.Margin = new Thickness(0, 1, 0, 0); words.Children.Add(body);
        Grid.SetColumn(words, 1); row.Children.Add(words);
        action.Margin = new Thickness(10, 0, 0, 0); action.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(action, 2); row.Children.Add(action);
        AutomationProperties.SetName(row, heading); return row;
    }
    private static Border Separator()
    {
        var line = new Border { Height = 1, Margin = new Thickness(10, 0, 10, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return line;
    }
    /// The code on white with its hint under it; the card takes focus so Escape closes it.
    private static Border CodeCard(string image, string hint)
    {
        var content = new StackPanel { Margin = new Thickness(12) };
        content.Children.Add(new Image { Source = BitmapFrame.Create(new Uri(image)), Width = 200, Height = 200, Stretch = Stretch.Uniform });
        content.Children.Add(new TextBlock { Text = hint, FontSize = 12, Foreground = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) });
        var card = new Border { Background = Brushes.White, CornerRadius = new CornerRadius(10), Child = content, Focusable = true, FocusVisualStyle = null };
        GuideContent.Identify(card, "update.route.qq.panel", hint); return card;
    }
}
