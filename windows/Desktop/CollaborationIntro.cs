using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// A border that screen readers hear as a named group; a plain Border has no automation peer.
internal sealed class GroupPeer(FrameworkElement owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
    protected override string GetClassNameCore() => Owner.GetType().Name;
}

/// Where Settings → Collaboration's guide stands: the pair is on and nothing
/// keeps it from working, a run has been seen, and one has ended. `Problem`
/// is what keeps the pair from working, with the pair card's own action.
internal sealed record CollaborationIntroState(bool On, bool Ran, bool Finished, bool CommandOnly,
    string? Problem = null, string? ProblemAction = null, string? ProblemActionLabel = null, bool CanTurnOn = true, bool Usable = true)
{
    internal bool AllDone => On && Ran && Finished;
}

/// How Claude calls Codex, as on the Mac: a looping demo of what happens beside
/// three steps. In Settings → Collaboration it is the first-run guide, whose
/// steps tick from the real state and which closes for good; in Help →
/// Collaboration the same card is a plain list with a way to the settings.
internal sealed class CollaborationIntro : Border
{
    private readonly UiText ui;
    private readonly bool help;
    private readonly Grid body = new();
    private readonly StackPanel steps = new();
    private readonly Step on, ask, watch;
    private readonly Button? finish;
    private string? copied;
    private readonly DispatcherTimer copyReset = new() { Interval = TimeSpan.FromSeconds(1.5) };
    private CollaborationIntroState? state;
    private string signature = "";
    internal CollaborationDemo Demo { get; }
    internal event Action? Dismissed;
    internal event Action? TurnOn;
    internal event Action<string>? Fix;
    internal event Action? OpenSettings;
    /// Two columns while both fit: the 300-point demo, a 16-point gap and 211 for the steps, so
    /// the Settings window at its smallest (860 wide) still shows them side by side, as on the Mac.
    internal const double Gap = 16, StepsWidth = 211, SideBySide = 300 + Gap + StepsWidth;

    internal CollaborationIntro(UiText ui, bool help)
    {
        this.ui = ui; this.help = help;
        TextElement.SetFontFamily(this, PacerFonts.Interface);
        CornerRadius = new CornerRadius(14); BorderThickness = new Thickness(1); Padding = new Thickness(16, 16, 16, help ? 18 : 14);
        SetResourceReference(BackgroundProperty, "SettingsCard"); SetResourceReference(BorderBrushProperty, "SettingsCardBorder");
        AutomationProperties.SetAutomationId(this, help ? "help.collaboration" : "settings.collaboration.intro");
        AutomationProperties.SetName(this, ui.Text("collab.intro.title"));
        var root = new StackPanel();

        // Claude's icon with Codex's over its corner, as on the pair card, then the title.
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14), LastChildFill = true };
        var icons = new Canvas { Width = 36, Height = 28, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        var claude = ProviderIcon.Tile("claude", 22, GuideArt.ProviderSymbol("claude"));
        var codex = ProviderIcon.Tile("codex", 20, GuideArt.ProviderSymbol("codex")); Canvas.SetLeft(codex, 14); Canvas.SetTop(codex, 7);
        icons.Children.Add(claude); icons.Children.Add(codex);
        DockPanel.SetDock(icons, Dock.Left); header.Children.Add(icons);
        if (!help)
        {
            // Settings' button style draws content as text; these buttons hold drawings, so they clear its template.
            var close = new Button { Width = 28, Height = 28, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                Cursor = Cursors.Hand, ContentTemplate = null, Content = Glyph("M2.5,2.5 L9.5,9.5 M9.5,2.5 L2.5,9.5", 12, "SettingsSecondary", 1.5) };
            close.Template = PlainTemplate();
            AutomationProperties.SetAutomationId(close, "settings.collaboration.intro.close"); AutomationProperties.SetName(close, ui.Text("collab.intro.close"));
            close.Click += (_, _) => Dismissed?.Invoke();
            DockPanel.SetDock(close, Dock.Right); header.Children.Add(close);
        }
        var title = Text(ui.Text("collab.intro.title"), 15, FontWeights.SemiBold); title.VerticalAlignment = VerticalAlignment.Center;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
        header.Children.Add(title);
        root.Children.Add(header);

        // The demo beside the steps, stacked when the page is narrow.
        Demo = new CollaborationDemo(ui) { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); body.ColumnDefinitions.Add(new ColumnDefinition());
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.Children.Add(Demo);
        steps.Margin = new Thickness(Gap, 4, 0, 0);
        AutomationProperties.SetName(steps, ui.Text("collab.intro.title"));
        on = new Step(1, ui.Text(help ? "collab.intro.step.on_help" : "collab.intro.step.on"), ui);
        ask = new Step(2, ui.Text("collab.intro.step.ask"), ui);
        watch = new Step(3, ui.Text("collab.intro.step.watch"), ui);
        steps.Children.Add(on.Root); steps.Children.Add(ask.Root); steps.Children.Add(watch.Root);
        Grid.SetColumn(steps, 1); body.Children.Add(steps);
        body.SizeChanged += (_, e) => Arrange(e.NewSize.Width);
        root.Children.Add(body);

        if (!help)
        {
            var footer = new Border { BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(0, 12, 0, 0), Margin = new Thickness(0, 14, 0, 0) };
            footer.SetResourceReference(BorderBrushProperty, "SettingsSeparator");
            finish = new Button { HorizontalAlignment = HorizontalAlignment.Right, MinWidth = 72 };
            AutomationProperties.SetAutomationId(finish, "settings.collaboration.intro.finish");
            finish.Click += (_, _) => Dismissed?.Invoke();
            footer.Child = finish; root.Children.Add(footer);
        }
        Child = root;
        copyReset.Tick += (_, _) => { copyReset.Stop(); copied = null; signature = ""; Render(); };
        Unloaded += (_, _) => { copyReset.Stop(); copied = null; };
        if (help) Update(new CollaborationIntroState(false, false, false, false));
    }

    /// Whether the steps sit beside the demo; read by the presentation checks.
    internal bool Wide => Grid.GetColumn(steps) == 1;
    /// The steps' done marks, in order; read by the presentation checks.
    internal bool[] Ticks => [on.Done, ask.Done, watch.Done];
    /// Whether each step's line end sits under its title; read by the presentation checks.
    internal bool[] EndsBelow => [on.Stacked, ask.Stacked, watch.Stacked];
    internal Button? Finish => finish;
    internal Button? TurnOnButton => on.Trailing.Children.OfType<Button>().FirstOrDefault();
    internal IEnumerable<Button> PhraseButtons => ask.Details.Children.OfType<WrapPanel>().SelectMany(panel => panel.Children.OfType<Button>());

    private void Arrange(double width)
    {
        bool wide = width >= SideBySide;
        if (wide == Wide) return;
        Grid.SetColumn(steps, wide ? 1 : 0); Grid.SetRow(steps, wide ? 0 : 1);
        steps.Margin = wide ? new Thickness(Gap, 4, 0, 0) : new Thickness(0, 16, 0, 0);
    }

    internal void Update(CollaborationIntroState value) { state = value; Render(); }

    /// A group named for the guide, so screen readers hear where its steps belong.
    protected override AutomationPeer OnCreateAutomationPeer() => new GroupPeer(this);

    private void Render()
    {
        if (state is not { } value) return;
        string next = string.Join("|", value, copied);
        if (next == signature) return;
        signature = next;
        if (help)
        {
            // Help lists the steps as they are; nothing is ticked or highlighted.
            on.Mark(false, false); ask.Mark(false, false); watch.Mark(false, false);
            on.Details.Children.Clear();
            var go = new Button { Content = ui.Text("collab.intro.open_settings"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
            AutomationProperties.SetAutomationId(go, "help.collaboration.open_settings");
            go.Click += (_, _) => OpenSettings?.Invoke();
            on.Details.Children.Add(go);
            ask.Details.Children.Clear();
            ask.Details.Children.Add(Phrases(["collab.intro.phrase.review", "collab.intro.phrase.opinion"]));
            ask.Details.Children.Add(CommandHint());
            watch.Details.Children.Clear();
            watch.Details.Children.Add(Note(ui.Text("collab.intro.watch_detail")));
            return;
        }

        on.Mark(value.On, !value.On);
        on.Trailing.Children.Clear(); on.Details.Children.Clear();
        if (value.On) on.Trailing.Children.Add(Note(ui.Text("collab.intro.on")));
        else if (value.Problem == null)
        {
            var turnOn = new Button { Content = ui.Text("collab.intro.turn_on"), IsEnabled = value.CanTurnOn, MinWidth = 56 };
            turnOn.SetResourceReference(StyleProperty, "SettingsProminentButton");
            AutomationProperties.SetAutomationId(turnOn, "settings.collaboration.intro.turn_on");
            turnOn.Click += (_, _) => TurnOn?.Invoke();
            on.Trailing.Children.Add(turnOn);
        }
        if (value.Problem is { } problem)
        {
            var line = Note(problem); line.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); line.Margin = new Thickness(0, 4, 0, 0);
            on.Details.Children.Add(line);
            if (value.ProblemAction is { } kind && value.ProblemActionLabel is { } label)
            {
                var fix = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), IsEnabled = value.Usable };
                AutomationProperties.SetAutomationId(fix, "settings.collaboration.intro.fix");
                fix.Click += (_, _) => Fix?.Invoke(kind);
                on.Details.Children.Add(fix);
            }
        }

        ask.Mark(value.Ran, value.On && !value.Ran);
        ask.Trailing.Children.Clear(); ask.Details.Children.Clear();
        if (value.Ran) ask.Trailing.Children.Add(Note(ui.Text("collab.intro.asked")));
        else
        {
            ask.Details.Children.Add(Phrases(value.CommandOnly ? ["collab.intro.phrase.command"] : ["collab.intro.phrase.review", "collab.intro.phrase.opinion"]));
            if (value.CommandOnly) { var only = Note(ui.Text("collab.intro.command_only")); only.Margin = new Thickness(0, 6, 0, 0); ask.Details.Children.Add(only); }
        }

        watch.Mark(value.Finished, value.On && value.Ran && !value.Finished);
        watch.Trailing.Children.Clear(); watch.Details.Children.Clear();
        if (value.Finished) watch.Trailing.Children.Add(Note(ui.Text("collab.intro.watched")));
        else watch.Details.Children.Add(Note(ui.Text("collab.intro.watch_detail")));

        if (finish != null)
        {
            finish.Content = ui.Text(value.AllDone ? "collab.done" : "collab.intro.got_it");
            if (value.AllDone) finish.SetResourceReference(StyleProperty, "SettingsProminentButton"); else finish.ClearValue(StyleProperty);
        }
    }

    /// Phrases to say to Claude, each copied with one click.
    private WrapPanel Phrases(string[] keys)
    {
        var panel = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (string key in keys)
        {
            string text = ui.Text(key);
            bool command = text.StartsWith('/');
            var label = Text(text, 12); if (command) label.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(label);
            if (copied == text)
            {
                var done = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6, 0, 0, 0) };
                done.Children.Add(Glyph("M2.5,6.2 L5,8.6 L9.6,3.6", 11, "SettingsSuccessText", 1.8));
                var word = Text(ui.Text("collab.intro.copied"), 12); word.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSuccessText"); word.Margin = new Thickness(3, 0, 0, 0);
                done.Children.Add(word); content.Children.Add(done);
            }
            else
            {
                var icon = Glyph("M4,4 H10.5 V10.5 H4 Z M8,2.2 H3.2 Q2,2.2 2,3.4 V8", 12, "SettingsSecondary", 1.2); icon.Margin = new Thickness(6, 0, 0, 0);
                content.Children.Add(icon);
            }
            var chip = new Button { Content = content, ContentTemplate = null, Height = 28, Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(0, 0, 6, 6), Cursor = Cursors.Hand,
                BorderThickness = new Thickness(1), Template = ChipTemplate() };
            chip.SetResourceReference(BackgroundProperty, "SettingsFill"); chip.SetResourceReference(BorderBrushProperty, "SettingsCardBorder");
            chip.MouseEnter += (_, _) => chip.SetResourceReference(BackgroundProperty, "SettingsHover");
            chip.MouseLeave += (_, _) => chip.SetResourceReference(BackgroundProperty, "SettingsFill");
            AutomationProperties.SetName(chip, ui.Text("collab.intro.copy").Replace("%@", text, StringComparison.Ordinal));
            AutomationProperties.SetAutomationId(chip, "collaboration.intro.phrase." + key[(key.LastIndexOf('.') + 1)..]);
            chip.Click += (_, _) => Copy(text);
            panel.Children.Add(chip);
        }
        return panel;
    }

    /// Puts a phrase on the clipboard. Another program may hold it for a moment;
    /// the phrase is still on screen. The presentation checks swap this so they
    /// leave the user's clipboard alone.
    internal static Func<string, bool> WriteClipboard = text =>
    {
        try { Clipboard.SetText(text); return true; } catch (ExternalException) { return false; }
    };

    private void Copy(string text)
    {
        if (!WriteClipboard(text)) return;
        copied = text; signature = ""; Render();
        copyReset.Stop(); copyReset.Start();
    }

    /// "Or type /pacer:codex followed by what to hand over", the command in code type.
    private TextBlock CommandHint()
    {
        var line = Note(""); line.Margin = new Thickness(0, 2, 0, 0);
        string[] parts = ui.Text("collab.intro.command_hint").Split("%@");
        line.Inlines.Add(new Run(parts[0]));
        var command = new Run("/pacer:codex") { FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        command.SetResourceReference(TextElement.ForegroundProperty, "SettingsPrimary");
        line.Inlines.Add(command);
        if (parts.Length > 1) line.Inlines.Add(new Run(parts[1]));
        return line;
    }

    private static TextBlock Text(string text, double size, FontWeight? weight = null)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, TextWrapping = TextWrapping.Wrap };
        block.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        return block;
    }

    private static TextBlock Note(string text)
    {
        var block = Text(text, 12); block.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); block.LineHeight = 18;
        return block;
    }

    internal static Path Glyph(string data, double size, string ink, double thickness)
    {
        var path = new Path { Data = Geometry.Parse(data), Width = 12, Height = 12, Stretch = Stretch.None, StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
            VerticalAlignment = VerticalAlignment.Center, LayoutTransform = new ScaleTransform(size / 12, size / 12) };
        path.SetResourceReference(Shape.StrokeProperty, ink);
        return path;
    }

    private static ControlTemplate PlainTemplate()
    {
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center); presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        var frame = new FrameworkElementFactory(typeof(Border));
        frame.SetValue(BackgroundProperty, Brushes.Transparent); frame.SetValue(CornerRadiusProperty, new CornerRadius(8));
        frame.AppendChild(presenter);
        return new ControlTemplate(typeof(Button)) { VisualTree = frame };
    }

    private static ControlTemplate ChipTemplate()
    {
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        var frame = new FrameworkElementFactory(typeof(Border));
        frame.SetValue(CornerRadiusProperty, new CornerRadius(8));
        frame.SetBinding(BackgroundProperty, new System.Windows.Data.Binding(nameof(Background)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        frame.SetBinding(BorderBrushProperty, new System.Windows.Data.Binding(nameof(BorderBrush)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        frame.SetBinding(BorderThicknessProperty, new System.Windows.Data.Binding(nameof(BorderThickness)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        frame.SetBinding(PaddingProperty, new System.Windows.Data.Binding(nameof(Padding)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        frame.AppendChild(presenter);
        return new ControlTemplate(typeof(Button)) { VisualTree = frame };
    }

    /// One numbered step: its mark (a number, or a check once done), its title
    /// with what sits at the end of the line, and what follows below.
    private sealed class Step
    {
        internal readonly Grid Root = new() { Margin = new Thickness(0, 0, 0, 16) };
        internal readonly StackPanel Trailing = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        internal readonly StackPanel Details = new();
        private readonly Border badge = new() { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 12, 0) };
        private readonly TextBlock number;
        private readonly Path check = Glyph("M2.5,6.2 L5,8.6 L9.6,3.6", 12, "SettingsSelectionText", 1.8);
        private readonly string name, doneName;
        internal bool Done { get; private set; }

        internal Step(int index, string title, UiText ui)
        {
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); Root.ColumnDefinitions.Add(new ColumnDefinition());
            number = new TextBlock { Text = index.ToString(CultureInfo.InvariantCulture), FontSize = 12, FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            check.HorizontalAlignment = HorizontalAlignment.Center; check.Stroke = Brushes.White;
            var face = new Grid(); face.Children.Add(number); face.Children.Add(check); badge.Child = face;
            Root.Children.Add(badge);
            var column = new StackPanel(); Grid.SetColumn(column, 1);
            var heading = new TextBlock { Text = title, FontSize = 13.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
            heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
            Trailing.Margin = new Thickness(0);
            var line = new TitleLine { MinHeight = 24 }; line.Children.Add(heading); line.Children.Add(Trailing);
            column.Children.Add(line); column.Children.Add(Details);
            Root.Children.Add(column);
            name = index.ToString(CultureInfo.InvariantCulture) + ". " + title;
            doneName = name + " · " + ui.Text("collab.intro.step_done");
            AutomationProperties.SetAutomationId(Root, "collaboration.intro.step." + index.ToString(CultureInfo.InvariantCulture));
            Mark(false, false);
        }

        /// Whether what ends the step's line sits under its title; read by the presentation checks.
        internal bool Stacked => Root.Children.OfType<StackPanel>().First().Children.OfType<TitleLine>().First().Stacked;

        /// A done step shows a check on green; the step to do next is ringed in the accent.
        internal void Mark(bool done, bool current)
        {
            Done = done;
            check.Visibility = done ? Visibility.Visible : Visibility.Collapsed;
            number.Visibility = done ? Visibility.Collapsed : Visibility.Visible;
            badge.BorderThickness = new Thickness(current && !done ? 1.5 : 0);
            if (done) badge.SetResourceReference(Border.BackgroundProperty, "SettingsSuccess");
            else if (current) badge.Background = Brushes.Transparent;
            else badge.SetResourceReference(Border.BackgroundProperty, "SettingsFill");
            badge.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
            number.SetResourceReference(TextBlock.ForegroundProperty, current ? "SettingsPrimary" : "SettingsSecondary");
            AutomationProperties.SetName(Root, done ? doneName : name);
        }
    }
}

/// A step's title with what ends its line (a button, or "On"): side by side, the
/// end at the right, while both fit on one line; otherwise the end moves under the
/// title, so the title is never squeezed onto two lines, as on the Mac.
internal sealed class TitleLine : Panel
{
    private const double Space = 8, Below = 4;
    internal bool Stacked { get; private set; }

    protected override Size MeasureOverride(Size available)
    {
        if (Children.Count < 2) return default;
        UIElement title = Children[0], end = Children[1];
        title.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        end.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        bool hasEnd = end.DesiredSize.Width > 0;
        Stacked = hasEnd && title.DesiredSize.Width + Space + end.DesiredSize.Width > available.Width;
        if (!Stacked)
            return new Size(title.DesiredSize.Width + (hasEnd ? Space + end.DesiredSize.Width : 0), Math.Max(title.DesiredSize.Height, end.DesiredSize.Height));
        title.Measure(new Size(available.Width, double.PositiveInfinity));
        end.Measure(new Size(available.Width, double.PositiveInfinity));
        return new Size(Math.Max(title.DesiredSize.Width, end.DesiredSize.Width), title.DesiredSize.Height + Below + end.DesiredSize.Height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (Children.Count < 2) return final;
        UIElement title = Children[0], end = Children[1];
        if (Stacked)
        {
            title.Arrange(new Rect(0, 0, final.Width, title.DesiredSize.Height));
            end.Arrange(new Rect(0, title.DesiredSize.Height + Below, end.DesiredSize.Width, end.DesiredSize.Height));
        }
        else
        {
            double height = final.Height;
            title.Arrange(new Rect(0, (height - title.DesiredSize.Height) / 2, Math.Max(0, final.Width - end.DesiredSize.Width - Space), title.DesiredSize.Height));
            end.Arrange(new Rect(final.Width - end.DesiredSize.Width, (height - end.DesiredSize.Height) / 2, end.DesiredSize.Width, end.DesiredSize.Height));
        }
        return final;
    }
}

/// The guide's demo, about ten seconds a loop: you ask in Claude, Pacer starts
/// Codex under that Claude task, its progress fills, the result goes back to
/// Claude, and the run is cleaned up when the turn ends. Without motion it
/// stays on the progress frame; the dots move between frames either way. The
/// pictures are hidden from screen readers; the dots name each step.
internal sealed class CollaborationDemo : Border
{
    internal const double Loop = 10.4;
    internal static readonly double[] Starts = [0, 2.4, 3.8, 7.0, 8.6];
    /// The frame each step shows when nothing moves.
    internal static readonly double[] Stills = [2.2, 2.8, 5.4, 7.3, 9.8];
    private static readonly Brush PanelFill = Frozen(0x24, 0x24, 0x28), PanelLine = Frozen(0x14, 0xFF, 0xFF, 0xFF), Ink = Frozen(0xF5, 0xF5, 0xF5),
        Quiet = Frozen(0xA1, 0xA1, 0xA6), Claude = Frozen(0xF2, 0x9C, 0x6B), ClaudeRing = Frozen(0x5A, 0xF2, 0x9C, 0x6B),
        Codex = Frozen(0x7D, 0xD6, 0xC4), CodexInk = Frozen(0x10, 0x30, 0x2A), Track = Frozen(0x1F, 0xFF, 0xFF, 0xFF), Rail = Frozen(0x29, 0xFF, 0xFF, 0xFF);
    private readonly UiText ui;
    private readonly DispatcherTimer timer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly Stopwatch clock = new();
    private double from;
    private bool motion = SystemParameters.ClientAreaAnimation;
    private int still = 2;
    private int beat = -1;
    private readonly string prompt;
    private readonly string[] captions;
    private readonly TextBlock typed = new() { FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Rectangle caret = new() { Width = 1.5, Height = 14, Margin = new Thickness(1, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly Ellipse send = new() { Width = 24, Height = 24 };
    private readonly Path sendArrow = new() { Data = Geometry.Parse("M6,10 V2 M2.5,5.5 L6,2 L9.5,5.5"), StrokeThickness = 1.6, Width = 12, Height = 12,
        StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
    private readonly Path claudeSpark = new() { Data = Geometry.Parse("M12,6 L13.3,10.7 L18,12 L13.3,13.3 L12,18 L10.7,13.3 L6,12 L10.7,10.7 Z"), Fill = Claude };
    private readonly Path claudeCheck = new() { Data = Geometry.Parse("M7.5,12.3 L10.6,15.2 L16.5,8.8"), Stroke = Claude, StrokeThickness = 2,
        StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
    private readonly TextBlock claudeStatus = new() { FontSize = 11, Foreground = Quiet };
    private readonly Border rail = new() { BorderThickness = new Thickness(1.5, 0, 0, 0), Height = 30, Margin = new Thickness(11, 0, 0, 0), Padding = new Thickness(10, 0, 0, 0) };
    private readonly Grid runLine = new() { RenderTransform = new TranslateTransform() };
    private readonly Grid cleanedLine = new() { Opacity = 0 };
    // A WPF ellipse draws its stroke inside its bounds: 14.8 puts the stroke's middle on the arc's 6.5-point radius.
    private readonly Ellipse pending = new() { Stroke = Codex, StrokeThickness = 1.8, StrokeDashArray = [1.44, 1.44], Opacity = 0.75, Width = 14.8, Height = 14.8 };
    private readonly Path arc = new() { Stroke = Codex, StrokeThickness = 1.8, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Grid done = new();
    private readonly TextBlock readings = new() { FontSize = 10.5, FontWeight = FontWeights.Medium, Foreground = Quiet, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock caption = new() { FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly List<(Button Button, Border Pill)> dots = [];

    internal CollaborationDemo(UiText ui)
    {
        this.ui = ui;
        prompt = ui.Text("collab.intro.phrase.review");
        captions = Enumerable.Range(1, 5).Select(index => ui.Text("collab.intro.demo." + index.ToString(CultureInfo.InvariantCulture))).ToArray();
        Width = 300; Height = 260; CornerRadius = new CornerRadius(14); Padding = new Thickness(14);
        TextElement.SetFontFamily(this, PacerFonts.Interface);
        SetResourceReference(BackgroundProperty, "SettingsBackground");
        AutomationProperties.SetAutomationId(this, "collaboration.intro.demo"); AutomationProperties.SetName(this, ui.Text("collab.intro.demo"));
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition()); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var picture = new QuietPanel();
        var stack = new StackPanel();
        stack.Children.Add(Bubble());
        var arrow = new Path { Data = Geometry.Parse("M5,1 V12 M2,9 L5,12 L8,9"), StrokeThickness = 1.4, Width = 10, Height = 14, Opacity = 0.55, Margin = new Thickness(0, 3, 0, 3),
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, HorizontalAlignment = HorizontalAlignment.Center };
        arrow.SetResourceReference(Shape.StrokeProperty, "SettingsSecondary");
        stack.Children.Add(arrow);
        stack.Children.Add(MiniPanel());
        picture.Children.Add(stack); root.Children.Add(picture);

        var footer = new DockPanel { Margin = new Thickness(0, 8, 0, 0), Height = 20 };
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        for (int index = 0; index < 5; index++)
        {
            var pill = new Border { Height = 6, CornerRadius = new CornerRadius(3), VerticalAlignment = VerticalAlignment.Center };
            var button = new Button { Content = pill, ContentTemplate = null, Height = 20, MinHeight = 0, Padding = new Thickness(2, 0, 2, 0), Background = Brushes.Transparent,
                BorderThickness = new Thickness(0), Cursor = Cursors.Hand };
            var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); presenter.SetValue(MarginProperty, new Thickness(2, 0, 2, 0));
            presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
            var frame = new FrameworkElementFactory(typeof(Border)); frame.SetValue(BackgroundProperty, Brushes.Transparent); frame.AppendChild(presenter);
            button.Template = new ControlTemplate(typeof(Button)) { VisualTree = frame };
            int step = index;
            AutomationProperties.SetName(button, ui.Text("collab.intro.demo.step").Replace("%1$d", (index + 1).ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
                .Replace("%2$@", captions[index], StringComparison.Ordinal));
            AutomationProperties.SetAutomationId(button, "collaboration.intro.demo.step." + (index + 1).ToString(CultureInfo.InvariantCulture));
            button.Click += (_, _) => Show(step);
            dots.Add((button, pill)); row.Children.Add(button);
        }
        DockPanel.SetDock(row, Dock.Left); footer.Children.Add(row);
        caption.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        footer.Children.Add(caption);
        Grid.SetRow(footer, 1); root.Children.Add(footer);
        Child = root;

        timer.Tick += (_, _) => Render(Now, true);
        Loaded += (_, _) => Refresh();
        Unloaded += (_, _) => { timer.Stop(); clock.Stop(); };
        IsVisibleChanged += (_, _) => Refresh();
        Render(Stills[still], false);
    }

    /// The step on screen and whether the loop runs; read by the presentation checks.
    internal int Beat => beat;
    internal bool Playing => timer.IsEnabled;
    internal string Typed => typed.Text;
    internal string Caption => caption.Text;

    /// The demo loops only with motion on and while it is on screen.
    internal void SetMotion(bool value) { if (motion == value) return; motion = value; Refresh(); }

    private double Now => (from + clock.Elapsed.TotalSeconds) % Loop;

    private void Refresh()
    {
        bool run = motion && IsLoaded && IsVisible;
        if (run)
        {
            if (!clock.IsRunning) clock.Start();
            if (!timer.IsEnabled) timer.Start();
            Render(Now, true);
        }
        else
        {
            timer.Stop(); clock.Stop();
            Render(Stills[still], false);
        }
    }

    /// A dot jumps to its step: the loop carries on from there, or the still frame changes.
    private void Show(int step)
    {
        still = step;
        if (timer.IsEnabled) { from = Starts[step]; clock.Restart(); Render(Now, true); }
        else Render(Stills[step], false);
    }

    private void Render(double t, bool moving)
    {
        int next = 0;
        for (int index = Starts.Length - 1; index >= 0; index--) if (t >= Starts[index]) { next = index; break; }
        bool changed = next != beat; beat = next;

        typed.Text = beat == 0 ? prompt[..Math.Min(prompt.Length, (int)(t / 1.8 * prompt.Length))] : prompt;
        caret.Visibility = beat == 0 && (int)(t / 0.4) % 2 == 0 ? Visibility.Visible : Visibility.Hidden;
        bool sent = beat > 0 || t > 1.9;
        if (sent) { send.SetResourceReference(Shape.FillProperty, "SettingsTintClaude"); sendArrow.SetResourceReference(Shape.StrokeProperty, "SettingsCard"); }
        else { send.SetResourceReference(Shape.FillProperty, "SettingsFill"); sendArrow.SetResourceReference(Shape.StrokeProperty, "SettingsSecondary"); }

        claudeStatus.Text = ui.Text(beat switch
        {
            0 => "collab.intro.demo.thinking", 1 or 2 => "collab.intro.demo.waiting", 3 => "collab.intro.demo.replying", _ => "collab.intro.demo.finished"
        });
        claudeSpark.Visibility = beat == 4 ? Visibility.Collapsed : Visibility.Visible;
        claudeCheck.Visibility = beat == 4 ? Visibility.Visible : Visibility.Collapsed;
        rail.BorderBrush = beat == 0 ? Brushes.Transparent : Rail;

        double fraction = beat == 2 ? (t - Starts[2]) / (Starts[3] - Starts[2]) : beat > 2 ? 1 : 0;
        pending.Visibility = beat <= 1 ? Visibility.Visible : Visibility.Collapsed;
        arc.Visibility = beat == 2 ? Visibility.Visible : Visibility.Collapsed;
        done.Visibility = beat >= 3 ? Visibility.Visible : Visibility.Collapsed;
        if (beat == 2) arc.Data = Arc(fraction);
        int rate = beat == 2 ? 82 + (int)Math.Round(5 * Math.Sin(t * 1000 / 260) + 3 * Math.Sin(t * 1000 / 97)) : 74;
        int seconds = beat == 2 ? (int)(fraction * 80) : beat > 2 ? 80 : 0;
        string time = (seconds / 60).ToString(CultureInfo.InvariantCulture) + ":" + (seconds % 60).ToString("00", CultureInfo.InvariantCulture);
        readings.Text = beat == 1 ? "— t/s · 0:00" : rate.ToString(CultureInfo.InvariantCulture) + " t/s · " + time;

        if (changed || !moving)
        {
            Fade(runLine, beat is >= 1 and <= 3 ? 1 : 0, moving, 0);
            Slide(beat == 0 ? 6 : 0, moving);
            Fade(cleanedLine, beat == 4 ? 1 : 0, moving, 0.25);
            caption.Text = captions[beat];
            for (int index = 0; index < dots.Count; index++)
            {
                var pill = dots[index].Pill;
                pill.Width = index == beat ? 18 : 6;
                pill.SetResourceReference(Border.BackgroundProperty, index == beat ? "SettingsTintCodex" : "SettingsSecondary");
                pill.Opacity = index == beat ? 1 : 0.45;
            }
        }
    }

    private static void Fade(UIElement element, double target, bool moving, double delay)
    {
        if (!moving) { element.BeginAnimation(OpacityProperty, null); element.Opacity = target; return; }
        if (Math.Abs(element.Opacity - target) < 0.001) return;
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(target, TimeSpan.FromSeconds(0.45))
            { BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }

    private void Slide(double target, bool moving)
    {
        var shift = (TranslateTransform)runLine.RenderTransform;
        if (!moving) { shift.BeginAnimation(TranslateTransform.YProperty, null); shift.Y = target; return; }
        shift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(target, TimeSpan.FromSeconds(0.45)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }

    /// The run's progress from the top, clockwise, on the 16-point ring.
    private static Geometry Arc(double fraction)
    {
        fraction = Math.Clamp(fraction, 0.001, 0.999);
        double angle = fraction * 2 * Math.PI, radius = 6.5;
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(new Point(8, 8 - radius), false, false);
            context.ArcTo(new Point(8 + radius * Math.Sin(angle), 8 - radius * Math.Cos(angle)), new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true, false);
        }
        geometry.Freeze(); return geometry;
    }

    private Border Bubble()
    {
        var bubble = new Border { Height = 40, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(10, 0, 6, 0) };
        bubble.SetResourceReference(BackgroundProperty, "SettingsCard"); bubble.SetResourceReference(BorderBrushProperty, "SettingsCardBorder");
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var spark = new Path { Data = Geometry.Parse("M8,1.5 L9.4,6.6 L14.5,8 L9.4,9.4 L8,14.5 L6.6,9.4 L1.5,8 L6.6,6.6 Z"), Width = 16, Height = 16,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        spark.SetResourceReference(Shape.FillProperty, "SettingsTintClaude");
        grid.Children.Add(spark);
        var line = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, ClipToBounds = true };
        typed.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); caret.SetResourceReference(Shape.FillProperty, "SettingsTintClaude");
        line.Children.Add(typed); line.Children.Add(caret);
        Grid.SetColumn(line, 1); grid.Children.Add(line);
        var button = new Grid { Width = 24, Height = 24, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        button.Children.Add(send); sendArrow.HorizontalAlignment = HorizontalAlignment.Center; sendArrow.VerticalAlignment = VerticalAlignment.Center; button.Children.Add(sendArrow);
        Grid.SetColumn(button, 2); grid.Children.Add(button);
        bubble.Child = grid;
        return bubble;
    }

    /// Pacer's panel as it shows the Claude task and its Codex run, always on the island's dark surface.
    private Border MiniPanel()
    {
        var panel = new Border { CornerRadius = new CornerRadius(12), Background = PanelFill, BorderBrush = PanelLine, BorderThickness = new Thickness(1), Padding = new Thickness(12, 8, 12, 6) };
        var stack = new StackPanel();
        var task = new Grid { Height = 40 };
        task.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); task.ColumnDefinitions.Add(new ColumnDefinition()); task.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new Grid { Width = 24, Height = 24, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        icon.Children.Add(new Ellipse { Width = 21, Height = 21, Stroke = ClaudeRing, StrokeThickness = 1.6 });
        var glyph = new Canvas { Width = 24, Height = 24 }; glyph.Children.Add(claudeSpark); glyph.Children.Add(claudeCheck); icon.Children.Add(glyph);
        task.Children.Add(icon);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = ui.Text("collab.intro.demo.task"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = Ink, TextTrimming = TextTrimming.CharacterEllipsis });
        claudeStatus.Margin = new Thickness(0, 2, 0, 0); words.Children.Add(claudeStatus);
        Grid.SetColumn(words, 1); task.Children.Add(words);
        var model = new TextBlock { Text = ui.Text("collab.intro.demo.claude_model"), FontSize = 10.5, FontWeight = FontWeights.Medium, Foreground = Claude, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(model, 2); task.Children.Add(model);
        stack.Children.Add(task);

        runLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); runLine.ColumnDefinitions.Add(new ColumnDefinition());
        runLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); runLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var ring = new Grid { Width = 16, Height = 16, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        ring.Children.Add(new Ellipse { Width = 14.8, Height = 14.8, Stroke = Track, StrokeThickness = 1.8 });
        ring.Children.Add(pending);
        var arcCanvas = new Canvas { Width = 16, Height = 16 }; arcCanvas.Children.Add(arc); ring.Children.Add(arcCanvas);
        done.Children.Add(new Ellipse { Width = 14, Height = 14, Fill = Codex });
        done.Children.Add(new Path { Data = Geometry.Parse("M4.8,8.2 L7,10.3 L11.2,5.8"), Stroke = CodexInk, StrokeThickness = 1.7, Width = 16, Height = 16,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round });
        ring.Children.Add(done);
        runLine.Children.Add(ring);
        var label = new TextBlock { Text = ui.Text("collab.intro.demo.run"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(label, 1); runLine.Children.Add(label);
        Grid.SetColumn(readings, 2); runLine.Children.Add(readings);
        var codexModel = new TextBlock { Text = ui.Text("collab.intro.demo.codex_model"), FontSize = 10.5, FontWeight = FontWeights.Medium, Foreground = Codex, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        Grid.SetColumn(codexModel, 3); runLine.Children.Add(codexModel);

        var cleaned = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        cleaned.Children.Add(new Path { Data = Geometry.Parse("M2,3.5 H10 M4.5,3.5 V2.2 H7.5 V3.5 M3.2,3.5 L3.8,10 H8.2 L8.8,3.5"), Stroke = Quiet, StrokeThickness = 1.1, Width = 12, Height = 12,
            Margin = new Thickness(0, 0, 6, 0), StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, VerticalAlignment = VerticalAlignment.Center });
        cleaned.Children.Add(new TextBlock { Text = ui.Text("collab.intro.demo.cleaned"), FontSize = 11, Foreground = Quiet, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        cleanedLine.Children.Add(cleaned);
        var lines = new Grid(); lines.Children.Add(runLine); lines.Children.Add(cleanedLine);
        rail.Child = lines;
        stack.Children.Add(rail);
        panel.Child = stack;
        return panel;
    }

    private static SolidColorBrush Frozen(byte red, byte green, byte blue) => Frozen(0xFF, red, green, blue);
    private static SolidColorBrush Frozen(byte alpha, byte red, byte green, byte blue)
    {
        var brush = new SolidColorBrush(Color.FromArgb(alpha, red, green, blue)); brush.Freeze(); return brush;
    }

    /// A group named for the demo, so screen readers hear its name and its five steps.
    protected override AutomationPeer OnCreateAutomationPeer() => new GroupPeer(this);

    /// The demo's pictures: on screen, but not read out; the dots and the region's name carry it.
    private sealed class QuietPanel : Grid
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
        private sealed class Peer(QuietPanel owner) : FrameworkElementAutomationPeer(owner)
        {
            protected override List<AutomationPeer>? GetChildrenCore() => null;
            protected override bool IsControlElementCore() => false;
            protected override bool IsContentElementCore() => false;
        }
    }
}
