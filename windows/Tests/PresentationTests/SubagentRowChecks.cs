using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CodexPacer.Windows;

/// A task's subagents, from a synthetic row: one dot each after its state in the
/// engine's order, 8 in a two-line row and 5 in one line with "+n" for the rest;
/// up to three lines on a rail under the task with the rest folded below them,
/// counted in its height; a one-line row keeps the dots without the lines, and
/// Claude cloud workers without dots keep their count.
internal static class SubagentRowChecks
{
    internal static async Task Run(string output)
    {
        EngineTaskRow Child(string id, string title, string phase, bool failed = false) =>
            new(id, "codex", title, phase, null, null, null, phase, "sparkle", null, "Sol 6.1", "high", null, false, null, "1:00", 0, false, failed, false, null, false);
        var running = new EngineSubagentLine(Child("sub-run", "worker · Add network tests", "running"), "running", "24.1", true, "3m", "worker · Add network tests, 24.1 t/s, 3m");
        var approval = new EngineSubagentLine(Child("sub-wait", "general-purpose · Run migrations", "waitingForInput"), "approval", null, false, "Waiting for approval · Bash",
            "general-purpose · Run migrations, Waiting for approval · Bash");
        var failed = new EngineSubagentLine(Child("sub-fail", "Explore · Search old docs", "completed", failed: true), "failed", null, false, "Failed · 30s",
            "Explore · Search old docs, Failed · 30s");
        string[] dots = ["attention", "running", "running", "failed", .. Enumerable.Repeat("completed", 8)];
        var parent = new EngineTaskRow("codex-parent", "codex", "Rename the API", "Waiting for subagents", null, null, null, "running", "sparkle", null,
            "Sol 6.1", "high", 96.4, true, null, "7:00", 0, false, false, false, null, false, RateText: "96.4",
            SubagentDots: dots, SubagentDotsText: "12 subagents, 2 running", SubagentLines: [approval, running, failed], SubagentsFolded: "9 more done");
        var row = new TaskRow(parent, showsDelegations: true); row.SetAnimations(false);
        var surface = new Border { Child = row, Padding = new Thickness(12), Background = new SolidColorBrush(Color.FromRgb(18, 19, 22)) };
        var window = new Window { Content = surface, Width = 460, Height = TaskRow.RowHeight(parent, null) + 60, ShowActivated = false, ShowInTaskbar = false };
        window.Show();
        try
        {
            await PresentationWait.UntilAsync(() => row.IsLoaded, "The task row must be in the visual tree");
            window.UpdateLayout();
            // Two lines: the person glyph, the first 8 dots in the engine's order, then how many more.
            var marks = row.TwoLineDots.Children.OfType<Ellipse>().ToList();
            var more = row.TwoLineDots.Children.OfType<TextBlock>().SingleOrDefault();
            Check(row.TwoLineDots.Visibility == Visibility.Visible && marks.Count == TaskRow.DotLimit && more?.Text == "+4",
                "A two-line row draws 8 dots and folds the rest into +n");
            Check(marks[0].Fill == PacerPalette.Attention && marks[1].Fill == PacerPalette.Provider("codex") && marks[3].Fill == PacerPalette.Danger
                && marks[^1].Fill is SolidColorBrush done && marks[^1].Fill != PacerPalette.Provider("codex") && done.Color != ((SolidColorBrush)PacerPalette.Danger).Color,
                "Dots take the attention, service, danger and grey colors of their subagents");
            Check(marks.All(mark => mark.Width == 5 && mark.Height == 5), "Dots are 5 points");
            Check(((TaskRowState)row.DataContext).AccessibleName.Contains("12 subagents, 2 running"), "Screen readers hear how many subagents and how many run");
            // Lines: three on the rail in the engine's order, the folded one last, as on the Mac.
            var lines = row.Subagents.Children.OfType<Grid>().ToList();
            string Text(Grid line) => string.Join(" ", line.Children.OfType<TextBlock>().Select(text =>
                text.Inlines.Count > 0 ? string.Concat(text.Inlines.OfType<System.Windows.Documents.Run>().Select(run => run.Text)) : text.Text));
            Check(row.SubagentRuns.Visibility == Visibility.Visible && lines.Count == 4 && lines.Take(3).All(line => line.Tag is EngineSubagentLine)
                && lines[3].Tag as string == TaskRow.FoldedTag && Text(lines[3]).Contains("9 more done"), "Three subagent lines, then the folded line under them");
            Check(lines.Take(3).All(line => Math.Abs(line.ActualHeight - TaskRow.DelegationHeight) < 0.5)
                && Math.Abs(lines[3].ActualHeight - TaskRow.FoldedHeight) < 0.5, "Subagent lines take the Codex runs' heights");
            Check(Text(lines[1]).Contains("24.1") && Text(lines[1]).Contains("t/s · 3m") && Text(lines[0]).Contains("Waiting for approval · Bash")
                && !Text(lines[0]).Contains("t/s"), "A writing subagent shows its speed and time; one waiting shows only its state");
            System.Windows.Documents.Run Detail(Grid line) => line.Children.OfType<TextBlock>().Single(text => Grid.GetColumn(text) == 4).Inlines
                .OfType<System.Windows.Documents.Run>().Last();
            TextBlock Title(Grid line) => line.Children.OfType<TextBlock>().Single(text => Grid.GetColumn(text) == 2);
            Check(Detail(lines[0]).Foreground == PacerPalette.Attention && Detail(lines[2]).Foreground == PacerPalette.Danger
                && Detail(lines[1]).Foreground == PacerPalette.Secondary, "What needs the user and a failure take their colors");
            Check(Title(lines[1]).Foreground == PacerPalette.Primary && Title(lines[2]).Foreground == PacerPalette.Secondary, "An ended subagent's label steps back");
            Check(!lines.SelectMany(SelfAndDescendants).OfType<Button>().Any() && !lines.SelectMany(SelfAndDescendants).OfType<FrameworkElement>().Any(value => value.ToolTip != null),
                "A subagent line has no Stop and no hover popup");
            Check(AutomationProperties.GetName(lines[1]) == running.AccessibilityText, "Each subagent line is named for screen readers");
            double lined = TaskRow.TwoLineHeight + 3 * TaskRow.DelegationHeight + TaskRow.FoldedHeight + TaskRow.DelegationRailBottom;
            Check(Math.Abs(TaskRow.RowHeight(parent, null) - lined) < 0.5 && Math.Abs(row.ActualHeight - lined) < 0.5, "The row's height counts its subagent lines");
            // The task and its subagent lines are separate targets.
            row.SetOpenAction(() => { }, "Open", false);
            MouseEventArgs Pointer(RoutedEvent kind) => new(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = kind };
            row.RaiseEvent(Pointer(Mouse.MouseEnterEvent));
            Check(row.HoverProgress == 1 && lines.All(line => !TaskRow.LineHighlighted(line)), "Hovering the task lights the task, not its subagent lines");
            row.SubagentRuns.RaiseEvent(Pointer(Mouse.MouseEnterEvent));
            Check(row.HoverProgress == 0, "Moving onto the subagent lines leaves the task itself unhighlighted");
            row.RaiseEvent(Pointer(Mouse.MouseLeaveEvent));
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(surface.ActualWidth), (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(surface);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(System.IO.Path.Combine(output, "island-subagent-rows.png"))) encoder.Save(file);

            // The island builds its rows again when the panel's choices change; so do these checks.
            async Task<TaskRow> Shown(EngineTaskRow value, PanelOptions? options)
            {
                var next = new TaskRow(value, options, showsDelegations: true); next.SetAnimations(false);
                surface.Child = next;
                await PresentationWait.UntilAsync(() => next.IsLoaded, "The rebuilt task row must be in the visual tree");
                window.UpdateLayout(); return next;
            }
            // Without the subagents field: no dots, no lines, no height for them.
            var hidden = PanelOptions.Default with { RowFields = ["rate", "turnTime", "model"] };
            row = await Shown(parent, hidden);
            Check(row.SubagentRuns.Visibility == Visibility.Collapsed && ((TaskRowState)row.DataContext).SubagentsVisible == Visibility.Collapsed
                && row.OneLineDots.Visibility == Visibility.Collapsed && TaskRow.RowHeight(parent, hidden) == TaskRow.TwoLineHeight,
                "The subagents field hides the dots and the lines");
            // One line keeps the dots, 5 of them, and drops the lines.
            var compact = PanelOptions.Default with { RowStyle = "oneLine" };
            row = await Shown(parent, compact);
            var compactMarks = row.OneLineDots.Children.OfType<Ellipse>().ToList();
            Check(row.OneLineDots.Visibility == Visibility.Visible && compactMarks.Count == TaskRow.CompactDotLimit
                && row.OneLineDots.Children.OfType<TextBlock>().SingleOrDefault()?.Text == "+7" && row.OneLineDots.Children.OfType<IconGlyph>().Count() == 1,
                "A one-line row draws 5 dots after the person glyph and folds the rest into +n");
            Check(row.SubagentRuns.Visibility == Visibility.Collapsed && TaskRow.RowHeight(parent, compact) == TaskRow.OneLineHeight
                && ((TaskRowState)row.DataContext).AccessibleName.Contains("12 subagents, 2 running"), "A one-line row keeps the dots without the lines");
            // Claude cloud workers come as a count without dots.
            var workers = parent with { Provider = "claude", Subagents = 2, SubagentText = "2", SubagentDots = null, SubagentDotsText = null, SubagentLines = null, SubagentsFolded = null };
            row = await Shown(workers, null);
            var state = (TaskRowState)row.DataContext;
            Check(state.SubagentsVisible == Visibility.Visible && state.SubagentCountVisible == Visibility.Visible && state.SubagentDotsVisible == Visibility.Collapsed
                && row.TwoLineDots.Children.Count == 0 && TaskRow.RowHeight(workers, null) == TaskRow.TwoLineHeight, "Workers without dots keep their count");
            Console.WriteLine("PASS subagent rows: ordered dots with +n (8 / 5), colored lines with the folded line under them, height, one-line dots only, worker count");
        }
        finally { window.Close(); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
