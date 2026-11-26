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
/// up to three lines on a rail under the task, laid out as the Codex runs (type and
/// name tags, title, then speed, state, time and model), with the rest folded below
/// them and counted in its height. A narrow line shrinks its title to 48 points
/// first and then drops the model, then the time; the task row does the same. A
/// one-line row keeps the dots without the lines, and Claude cloud workers without
/// dots keep their count.
internal static class SubagentRowChecks
{
    internal static async Task Run(string output)
    {
        // The variant chosen: the fullest whose readings fit beside the tags and the shortest title.
        Check(TaskLinePanel.Choose(500, 40, 200, [150, 100, 60]) == 0 && TaskLinePanel.Choose(246, 40, 200, [150, 100, 60]) == 0
            && TaskLinePanel.Choose(245, 40, 200, [150, 100, 60]) == 1 && TaskLinePanel.Choose(195, 40, 200, [150, 100, 60]) == 2
            && TaskLinePanel.Choose(100, 40, 200, [150, 100, 60]) == 2 && TaskLinePanel.Choose(188, 0, 30, [150, 100, 60]) == 0,
            "Readings drop the model, then the time, only once the title is at its minimum");

        EngineTaskRow Child(string id, string title, string phase, bool failed = false) =>
            new(id, "codex", title, phase, null, null, null, phase, "sparkle", null, "Sol 6.1", "high", null, false, null, "1:00", 0, false, failed, false, null, false);
        var approval = new EngineSubagentLine(Child("sub-wait", "Run migrations", "waitingForInput"), "approval", null, false, "", "Run migrations, Waiting for approval · Bash",
            Title: "Run migrations", Model: "Sonnet 5.5", StatusText: "Waiting for approval · Bash", Time: "2m");
        var running = new EngineSubagentLine(Child("sub-run", "Add network tests", "running"), "running", "24.1", true, "", "worker Linnaeus, Add network tests, 24.1 t/s, 3m",
            TypeTag: "worker", NameTag: "Linnaeus", Title: "Add network tests", Model: "Sol 6.1", Time: "3m");
        var failed = new EngineSubagentLine(Child("sub-fail", "Search old docs", "completed", failed: true), "failed", null, false, "", "Explore, Search old docs, Failed, 30s",
            TypeTag: "Explore", Title: "Search old docs", Model: "Haiku 5.5", StatusText: "Failed", Time: "30s");
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
            TaskLinePanel Content(Grid line) => line.Children.OfType<TaskLinePanel>().Single();
            List<System.Windows.Documents.Run> Runs(Grid line) => ((TextBlock)Content(line).ShownReadings).Inlines.OfType<System.Windows.Documents.Run>().ToList();
            string Readings(Grid line) => string.Concat(Runs(line).Select(run => run.Text));
            TextBlock Title(Grid line) => (TextBlock)Content(line).Title;
            List<TextBlock> Tags(Grid line) => SelfAndDescendants(Content(line)).OfType<Border>().Select(tag => (TextBlock)tag.Child).ToList();
            Check(row.SubagentRuns.Visibility == Visibility.Visible && lines.Count == 4 && lines.Take(3).All(line => line.Tag is EngineSubagentLine)
                && lines[3].Tag as string == TaskRow.FoldedTag && lines[3].Children.OfType<TextBlock>().Single().Text == "9 more done",
                "Three subagent lines, then the folded line under them");
            Check(lines.Take(3).All(line => Math.Abs(line.ActualHeight - TaskRow.DelegationHeight) < 0.5)
                && Math.Abs(lines[3].ActualHeight - TaskRow.FoldedHeight) < 0.5, "Subagent lines take the Codex runs' heights");
            Check(Readings(lines[1]) == "24.1 t/s · 3m · Sol 6.1" && Readings(lines[0]) == "Waiting for approval · Bash · 2m · Sonnet 5.5"
                && Readings(lines[2]) == "Failed · 30s · Haiku 5.5", "Speed or state, then time and model, joined by dots");
            Check(Runs(lines[1])[0].Foreground == PacerPalette.Primary && Runs(lines[1])[^1].Foreground == PacerPalette.Provider("codex")
                && Runs(lines[0])[0].Foreground == PacerPalette.Attention && Runs(lines[2])[0].Foreground == PacerPalette.Danger
                && Runs(lines[2])[^1].Foreground == PacerPalette.Secondary, "Fresh speed, waiting and failed states and the running model take their colors");
            Check(Title(lines[1]).Text == "Add network tests" && Title(lines[1]).Foreground == PacerPalette.Primary && Title(lines[2]).Foreground == PacerPalette.Secondary,
                "The title comes from the line, and an ended subagent's title steps back");
            Check(Tags(lines[0]).Count == 0 && Tags(lines[1]).Select(tag => tag.Text).SequenceEqual(["worker", "Linnaeus"])
                && Tags(lines[1])[0].Foreground == PacerPalette.Provider("codex") && Tags(lines[1])[1].Foreground == PacerPalette.Secondary
                && Tags(lines[2]).Single().Foreground == PacerPalette.Secondary,
                "The type tag takes the service's color while running and steps back once ended; the name tag stays quiet");
            Check(!lines.SelectMany(SelfAndDescendants).OfType<Button>().Any() && !lines.SelectMany(SelfAndDescendants).OfType<FrameworkElement>().Any(value => value.ToolTip != null),
                "A subagent line has no Stop and no hover popup");
            Check(AutomationProperties.GetName(lines[1]) == running.AccessibilityText, "Each subagent line is named for screen readers");
            double lined = TaskRow.TwoLineHeight + 3 * TaskRow.DelegationHeight + TaskRow.FoldedHeight + TaskRow.DelegationRailBottom;
            Check(Math.Abs(TaskRow.RowHeight(parent, null) - lined) < 0.5 && Math.Abs(row.ActualHeight - lined) < 0.5, "The row's height counts its subagent lines");
            Check(!row.DropsTime && !row.DropsModel && row.ModelText.Visibility == Visibility.Visible && row.TimeRun.Text == "7:00", "A wide row keeps all its readings");
            Check(lines.Take(3).All(line => Content(line).VariantCount == 3), "A line with a model and a time has three reading variants");
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
            // Narrow: each line keeps its tags whole and its title at 48 points or more, and drops readings from the end.
            window.Width = 330; row = await Shown(parent, null);
            var narrow = row.Subagents.Children.OfType<Grid>().Take(3).ToList();
            Check(narrow.Any(line => Content(line).Chosen > 0) && narrow.All(line => Title(line).ActualWidth >= TaskLinePanel.TitleMinimum - 0.5)
                && narrow.All(line => SelfAndDescendants(Content(line)).OfType<Border>().All(tag => Math.Abs(tag.ActualWidth + tag.Margin.Left + tag.Margin.Right - tag.DesiredSize.Width) < 0.5))
                && narrow.All(line => Math.Abs(Content(line).ShownReadings.ActualWidth - Content(line).ShownReadings.DesiredSize.Width) < 0.5),
                "A narrow line shrinks its title to its minimum, keeps tags and readings whole, and drops the model before the time");
            Check(narrow.Where(line => Content(line).Chosen == 1).All(line => !Readings(line).Contains("Sol") && !Readings(line).Contains("Sonnet") && !Readings(line).Contains("Haiku"))
                && narrow.Where(line => Content(line).Chosen == 2).All(line => Readings(line) is "24.1 t/s" or "Waiting for approval · Bash" or "Failed"),
                "The model goes first, then the time; the speed or state stays");
            // The task row itself: each line decides on its own width. A long time drops while the model still fits...
            var bare = parent with { SubagentLines = null, SubagentsFolded = null };
            row = await Shown(bare with { TurnTime = "12 hours 34 minutes 56 seconds" }, null);
            Check(row.DropsTime && !row.DropsModel && string.IsNullOrEmpty(row.TimeRun.Text) && row.ModelText.Visibility == Visibility.Visible,
                "The first line drops its time without taking the second line's model");
            // ...and at the narrowest both go, while the speed stays.
            window.Width = 200; row = await Shown(bare, null);
            Check(row.DropsTime && row.DropsModel && row.ModelText.Visibility == Visibility.Collapsed && string.IsNullOrEmpty(row.TimeRun.Text),
                "A narrow task row keeps its speed and drops the model and the time");
            window.Width = 460;
            // A tag past 120 points keeps its start and end around an ellipsis; long tags widen the panel's probe.
            string longName = "general-purpose-research-assistant-with-a-long-role";
            var tagged = running with { TypeTag = longName, NameTag = longName, Title = new string('T', 120) };
            row = await Shown(parent with { SubagentLines = [tagged] }, null);
            var tagLine = row.Subagents.Children.OfType<Grid>().First();
            var longTags = Tags(tagLine);
            Check(longTags.Count == 2 && longTags.All(tag => tag.Text.StartsWith("gen", StringComparison.Ordinal) && tag.Text.EndsWith("role", StringComparison.Ordinal)
                && tag.Text.Contains('…') && tag.Text.Length < longName.Length)
                && SelfAndDescendants(Content(tagLine)).OfType<Border>().All(tag => tag.ActualWidth <= TaskRow.TagWidthLimit + 0.5),
                "A long tag keeps its start and end around a middle ellipsis, at most 120 points wide");
            Check(TaskRow.MiddleTrim("short", 100, value => value.Length * 6) == "short"
                && TaskRow.MiddleTrim("abcdefghij", 30, value => value.Length * 6) == "ab…ij", "Middle truncation keeps as much of both ends as fits");
            Check(row.IdealWidth() >= 22 + 12 + 20 + 8 + 2 * TaskRow.TagWidthLimit - 1 + 2 * TaskLinePanel.TagGap + 220,
                "Each tag counts in the panel's width on its own, beside a title measured up to 220 points");
            // Only the variants that read differently: no model leaves two, no model or time leaves one.
            row = await Shown(parent with { SubagentLines = [running with { Model = null }, failed with { Model = null, Time = null }] }, null);
            var spare = row.Subagents.Children.OfType<Grid>().Where(line => line.Tag is EngineSubagentLine).ToList();
            Check(Content(spare[0]).VariantCount == 2 && Content(spare[1]).VariantCount == 1, "A line builds only the reading variants that differ");

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
            Console.WriteLine("PASS subagent rows: ordered dots with +n (8 / 5), tagged lines with speed · time · model and the folded line, "
                + "narrow lines and rows dropping model then time, height, one-line dots only, worker count");
        }
        finally { window.Close(); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
