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
using CodexPacer.Windows;

/// Codex for Claude runs under their Claude task, from a synthetic row: one
/// line each with the ring or end mark, label, speed, time, model and effort
/// always on the line, a finished run keeping its final speed and time, Stop
/// only while hovered, the details for screen readers, and no hover popup.
internal static class DelegationRowChecks
{
    internal static async Task Run(string output)
    {
        IReadOnlyList<IReadOnlyList<string>> details = [["Mode", "Review · Read-only"], ["Model", "Sol 6.2 · high · Standard speed"]];
        var running = new EngineTaskRow("codex-run-fixture", "codex", "Review the login change", "Working", null, null, null, "running", "sparkle", null,
            "Sol 6.2", "high", 86, true, null, "1:20", 0, false, false, false, null, false, RateText: "86.0",
            ProgressState: "reported", ProgressFraction: 0.4, ProgressText: "40%", ProgressMode: "working", ParentID: "claude-row-fixture", CanStop: true, DetailLines: details);
        var finished = new EngineTaskRow("codex-run-done", "codex", "Implement async loading", "Done", null, null, null, "completed", "checkmark.circle", null,
            "Sol 6.2", "medium", 74, false, null, "4:05", 0, false, false, true, null, false, RateText: "74.0", ParentID: "claude-row-fixture", CanStop: false);
        var parent = new EngineTaskRow("claude-row-fixture", "claude", "Fix login refresh", "Waiting for Codex", null, null, null, "running", "sparkle", null,
            "Opus 5.5", "high", null, false, null, "1:20", 0, false, false, false, null, false, DelegatedText: "Codex 2", Delegations: [running, finished]);
        var row = new TaskRow(parent, showsDelegations: true); row.SetAnimations(false);
        string? stopped = null; row.SetStopAction(id => stopped = id, "Stop this Codex run");
        // The island's dark surface, so the capture reads as it would on screen.
        var surface = new Border { Child = row, Padding = new Thickness(12), Background = new SolidColorBrush(Color.FromRgb(18, 19, 22)) };
        var window = new Window { Content = surface, Width = 460, Height = TaskRow.RowHeight(parent, null) + 60, ShowActivated = false, ShowInTaskbar = false };
        window.Show();
        try
        {
            await PresentationWait.UntilAsync(() => row.IsLoaded, "The task row must be in the visual tree");
            window.UpdateLayout();
            var lines = Descendants(row).OfType<Grid>().Where(line => line.Tag is EngineTaskRow).ToList();
            Check(lines.Count == 2, "Each Codex run has its own line under its Claude task");
            Check(!lines.SelectMany(SelfAndDescendants).OfType<FrameworkElement>().Any(value => value.ToolTip != null), "A run line carries no hover popup, Stop included");
            // The trailing readings are runs of one text block.
            string Line(Grid line) => string.Join(" ", line.Children.OfType<TextBlock>().Select(text =>
                text.Inlines.Count > 0 ? string.Concat(text.Inlines.OfType<System.Windows.Documents.Run>().Select(run => run.Text)) : text.Text));
            Check(Line(lines[0]).Contains("Review the login change") && Line(lines[0]).Contains("86.0") && Line(lines[0]).Contains("t/s")
                && Line(lines[0]).Contains("1:20") && Line(lines[0]).Contains("Sol 6.2") && Line(lines[0]).Contains("high"),
                "A running run shows its speed, time, model and effort on the line");
            Check(Line(lines[1]).Contains("74.0") && Line(lines[1]).Contains("4:05") && Line(lines[1]).Contains("medium"),
                "A finished run keeps its final speed and time on the line");
            var stops = lines.Select(line => line.Children.OfType<Button>().Single()).ToList();
            Check(stops.All(button => button.Visibility == Visibility.Hidden) && lines.All(line => TaskRow.StopState(line) == (false, false)),
                "Stop shows only while the line is hovered, and the readings are whole until then");
            // No room is kept for Stop: it lies over the readings' end, inside the line.
            var readings = lines.Select(line => line.Children.OfType<TextBlock>().Single(text => Grid.GetColumn(text) == 4)).ToList();
            Check(lines.Zip(readings).All(pair => pair.First.ActualWidth - (pair.Second.TranslatePoint(new Point(pair.Second.ActualWidth, 0), pair.First).X) < 8)
                && lines.All(line => line.ColumnDefinitions.Count == 5) && stops.All(button => Grid.GetColumn(button) + Grid.GetColumnSpan(button) == 5),
                "The readings reach the line's end, and Stop shares their place instead of keeping its own");
            Check(AutomationProperties.GetHelpText(lines[0]).Contains("Review · Read-only") && AutomationProperties.GetHelpText(lines[1]).Length == 0,
                "Screen readers get the run's details without hovering");
            Check(stopped == null, "Nothing stops a run without a click");
            // The task and its runs are separate targets: the task's highlight covers its own row only,
            // and each run line has its own, hidden until that line is hovered.
            row.SetOpenAction(() => { }, "Open", false);
            MouseEventArgs Pointer(System.Windows.RoutedEvent kind) => new(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = kind };
            row.RaiseEvent(Pointer(Mouse.MouseEnterEvent)); window.UpdateLayout();
            var taskHighlight = Descendants(row).OfType<Border>().First(border => border.Opacity == 1 && border.Background == row.Background);
            Check(row.HoverProgress == 1 && Math.Abs(taskHighlight.ActualHeight - TaskRow.RowHeight(null)) < 0.5
                && row.ActualHeight > taskHighlight.ActualHeight + TaskRow.DelegationHeight, "The task's highlight covers its own row, not the runs under it");
            Check(lines.All(line => !TaskRow.LineHighlighted(line)), "A run line lights up only while it is hovered, never with its task");
            row.Runs.RaiseEvent(Pointer(Mouse.MouseEnterEvent));
            Check(row.HoverProgress == 0, "Moving onto the task's Codex runs leaves the task itself unhighlighted");
            row.RaiseEvent(Pointer(Mouse.MouseLeaveEvent));
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(surface.ActualWidth), (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(surface);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(Path.Combine(output, "island-delegation-rows.png"))) encoder.Save(file);
            Console.WriteLine("PASS Codex for Claude rows: on-line readings, final speed and time, hover-only Stop, details for screen readers, no hover popups");
        }
        finally { window.Close(); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
