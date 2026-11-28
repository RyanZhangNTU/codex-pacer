using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Windows.Markup;
using CodexPacer.Windows;
using FilePath = System.IO.Path;

internal static class ContextLevelChecks
{
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static bool Near(double left, double right, double tolerance = 0.00001) => Math.Abs(left - right) < tolerance;
    private static EngineContextLevel Level(double fraction) => new((long)Math.Round(fraction * 1000), 1000, fraction, 1800000000);
    private static EngineTaskRow Working(UiText ui) => new(Guid.NewGuid().ToString(), "codex", ui.Text("demo.optimize"), ui.Text("activity.tool"),
        null, null, null, "running", "terminal", null, "Sol", null, null, false, null, "1:20", 0, false, false, false, null, false,
        ProgressState: "reported", ProgressMode: "working", ProgressFraction: 0.43, ContextLevel: Level(0.5));

    internal static async Task Run(string output)
    {
        var host = new StackPanel();
        var window = new Window { Content = host, Width = 420, Height = 300, Left = -20000, Top = -20000, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false };
        bool wasLight = PacerPalette.Light;
        try
        {
            window.Show();
            foreach (bool dark in new[] { false, true })
            {
                PacerPalette.ApplyTone(!dark);
                foreach (bool chinese in new[] { false, true }) await CheckRows(host, output, UiText.For(chinese), dark);
            }
            await CheckMotion(host);
        }
        finally { window.Close(); PacerPalette.ApplyTone(wasLight); }
    }

    private static async Task CheckRows(StackPanel host, string output, UiText ui, bool dark)
    {
        var working = Working(ui);
        var ended = working with { Phase = "completed", Status = ui.Text("activity.progress_done"), Symbol = "checkmark.circle", Unread = true,
            ProgressMode = "done", ProgressFraction = 1 };
        var asking = working with { Phase = "waitingForInput", Status = ui.Text("activity.waiting"), Symbol = "questionmark.bubble", Attention = "input", ContextLevel = null };
        var compacting = working with { CompactingSince = 1800000000, Status = ui.Text("activity.compacting_context") };
        var row = new TaskRow(working, showsDelegations: true, ui: ui) { Language = XmlLanguage.GetLanguage(ui.Language) };
        row.SetAnimations(false);
        var surface = new Border { Background = PacerPalette.Surface, Padding = new Thickness(8), Child = row };
        host.Children.Clear(); host.Children.Add(surface);
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var icon = row.StatusIcon;
        foreach (var (name, value) in new[] { ("working", working), ("ended", ended), ("read", ended with { Dimmed = true, Unread = false }),
            ("needs-user", asking), ("compacting", compacting) })
        {
            row.Update(value, null); surface.UpdateLayout();
            Check(icon.ShowsLevel == (value.ContextLevel != null), name + " level visibility");
            var bitmap = Bitmap(icon, 4);
            double AlphaAt(int y)
            {
                var pixel = new byte[4]; bitmap.CopyPixels(new Int32Rect(56, y * 4, 1, 1), pixel, 4, 0);
                return pixel[3] / 255.0;
            }
            if (name is "working" or "ended" or "read")
            {
                double top = name == "working" ? 0.06 : name == "ended" ? 0.42 : 0.08;
                double bottom = name == "working" ? 0.25 : name == "ended" ? 1 : 0.21;
                Check(Near(AlphaAt(6), top, 0.02) && Near(AlphaAt(22), bottom, 0.04), name + " renders the two tones inside its disc");
            }
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(Bitmap(surface, 2)));
            using var file = File.Create(FilePath.Combine(output, $"context-{name}-{ui.Language}-{(dark ? "dark" : "light")}.png"));
            encoder.Save(file);
        }
        foreach (double area in new[] { 0, 0.2, 0.5, 0.989, 0.99, 1 })
        {
            row.Update(working with { ContextLevel = Level(area) }, null);
            double x = 1 - 2 * icon.LevelHeightShown;
            Check(Near((Math.Acos(x) - x * Math.Sqrt(1 - x * x)) / Math.PI, area), "The filled segment occupies the reported area");
            var brush = (LinearGradientBrush)icon.Children.OfType<Ellipse>().First().Fill;
            var stops = brush.GradientStops;
            Check(Near((stops[3].Offset - stops[1].Offset) * TaskStatusIcon.OrbSide, area > 0 && area < 0.99 ? 0.7 : 0)
                && stops[1].Color.A == 102, "Only an intermediate fill draws the surface line, with the same provider ink throughout");
        }
        foreach (string symbol in new[] { "questionmark.bubble", "hand.raised" })
        {
            row.Update(asking with { ContextLevel = Level(0.6), CompactingSince = 1800000000, Symbol = symbol }, null);
            Check(!icon.ShowsLevel && icon.Face == "solid:" + symbol, "A request for the user keeps its whole disc");
        }

        string usage = ui.Language == "en" ? "Context 64% used" : "上下文已用 64%";
        string compact = ui.Text("activity.compacting_context");
        var measured = working with { ContextLevel = Level(0.635) };
        var child = new EngineSubagentLine(measured with { Id = "child" }, "running", null, false, "", "Child");
        var parent = measured with { Delegations = [compacting with { Id = "run" }], SubagentLines = [child] };
        row.Update(parent, null);
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var peer = UIElementAutomationPeer.CreatePeerForElement(row)!;
        Check(peer.GetName().Contains(measured.Status + ", " + usage), "The row reads context after its status");
        var children = peer.GetChildren()!.Select(item => item.GetName()).ToArray();
        Check(children.Any(name => name.Contains(usage)) && children.Any(name => name.Contains(compact)), "Both child rails expose context through UI Automation");
        var childIcon = row.Subagents.Children.OfType<Grid>().Single().Children.OfType<TaskStatusIcon>().Single();
        var runIcon = row.Delegations.Children.OfType<Grid>().Single().Children.OfType<TaskStatusIcon>().Single();
        Check(childIcon.ShowsLevel && runIcon.Face == "compacting", "Both child icons use their own measurement");
        row.SetAnimations(true);
        var pressedChild = child with { Row = child.Row with { CompactingSince = compacting.CompactingSince, Status = compact } };
        row.Update(parent with { SubagentLines = [pressedChild] }, null);
        Check(childIcon.Face == "compacting" && childIcon.GlyphLayers == 2 && childIcon.Pressing, "A child enters compaction in place");
        row.SetAnimations(false);
        row.Update(compacting with { ContextLevel = null }, PanelOptions.Default with { RowStyle = "oneLine", ShowContextLevel = false });
        Check(!icon.ShowsLevel && icon.Face == "working:terminal" && peer.GetName().Split(compact).Length == 2
            && ((TaskRowState)row.DataContext).OneLineStatusVisible == Visibility.Visible, "With context hidden the ordinary glyph still leads with the compacting status");
        row.Update(measured with { ContextLevel = Level(0.625) }, null);
        Check(peer.GetName().Contains("63%"), "Half percentages round away from zero");
    }

    private static RenderTargetBitmap Bitmap(FrameworkElement element, int scale)
    {
        var size = new Size(element.ActualWidth, element.ActualHeight);
        var drawing = new DrawingVisual();
        var brush = new VisualBrush(element) { ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(size) };
        using (var context = drawing.RenderOpen()) context.DrawRectangle(brush, null, new Rect(size));
        var image = new RenderTargetBitmap((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        image.Render(drawing);
        return image;
    }

    private static async Task CheckMotion(StackPanel host)
    {
        host.Children.Clear();
        var icon = new TaskStatusIcon(); host.Children.Add(icon);
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var working = Working(UiText.For(false)) with { ProgressState = "pending", ContextLevel = Level(0.9) };
        var ink = Colors.Orange;
        icon.Show(working, ink, true);
        double since = (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds - 1;
        var compact = working with { ProgressState = "reported", ProgressFraction = 0.62, CompactingSince = since };
        icon.Show(compact, ink, true);
        Check(icon.GlyphLayers == 2 && icon.Pressing && !icon.RhythmsRunning && icon.Ring.Loops == "" && Near(icon.Ring.DisplayFraction, 0.62),
            "The first estimate arrives with the press and holds while the glyphs crossfade");
        var glyph = icon.Children.OfType<Grid>().Last().Children.OfType<Canvas>().Last();
        var paths = glyph.Children.OfType<System.Windows.Shapes.Path>().ToArray();
        Check(paths.Length == 3 && Near(paths[0].Data.Bounds.Width * 14 / 24, 9.2, 0.05) && paths.All(path => path.StrokeThickness == 2)
            && glyph.RenderTransform.Value.IsIdentity, "The three-part compress glyph enters at full size");
        var rebuilt = new TaskStatusIcon(); host.Children.Add(rebuilt);
        foreach (string mode in new[] { "waiting", "longStep", "working" })
        {
            rebuilt.Show(compact with { ProgressMode = mode, ProgressFraction = 0.7 }, ink, true);
            Check(rebuilt.Ring.Loops == "" && Near(rebuilt.Ring.DisplayFraction, 0.62), "The rebuilt ring holds through " + mode);
        }
        await PresentationWait.UntilAsync(() => rebuilt.LevelHeightShown < TaskStatusIcon.LevelHeight(0.9) - 0.01
            && Near(rebuilt.LevelHeightShown, icon.LevelHeightShown, 0.008), "Rebuilt water presses in phase with the original");
        var stops = ((LinearGradientBrush)icon.Children.OfType<Ellipse>().First().Fill).GradientStops;
        double pressure = (1 - icon.LevelHeightShown / TaskStatusIcon.LevelHeight(0.9)) / 0.05;
        double Offset(int index) => ((TranslateTransform)((TransformGroup)paths[index].RenderTransform).Children[1]).Y;
        Check(Near(Offset(1), 1.3 * pressure) && Near(Offset(2), -Offset(1)) && Near(stops[1].Color.A / 255.0, 0.4 + 0.12 * pressure, 0.003),
            "Both chevrons and the gradient density follow the same press");
        rebuilt.Visibility = Visibility.Hidden;
        Check(!rebuilt.Pressing, "Hidden icons release the press clock");
        rebuilt.Visibility = Visibility.Visible; rebuilt.SetMotion(false);
        Check(!rebuilt.Pressing && rebuilt.Face == "compacting" && Near(rebuilt.LevelHeightShown, TaskStatusIcon.LevelHeight(0.9)), "Reduced motion keeps the static symbol");
        rebuilt.SetMotion(true);
        await PresentationWait.UntilAsync(() => rebuilt.LevelHeightShown < TaskStatusIcon.LevelHeight(0.9) - 0.01, "Visible motion resumes the press");
        double release = rebuilt.LevelHeightShown;
        var next = working with { ProgressState = "reported", ProgressFraction = 0.7, ContextLevel = Level(0.25) };
        rebuilt.Show(next, ink, true);
        Check(rebuilt.Sweep is { Duration: 0.9 } sweep && Near(sweep.From, release, 0.002) && rebuilt.Face == "working:terminal"
            && !rebuilt.Pressing && rebuilt.RhythmsRunning && rebuilt.Ring.Loops == "flow", "Release eases from the pressed height and restores working motion");
        rebuilt.Show(compact with { CompactingSince = since + 1, ProgressFraction = 0.31 }, ink, true);
        Check(Near(rebuilt.Ring.DisplayFraction, 0.31), "A new start captures a new estimate");
        rebuilt.Show(next with { ContextLevel = null }, ink, true);
        rebuilt.Show(next, ink, true);
        Check(rebuilt.Sweep?.Duration == 0.9, "Release survives a missing replacement reading");
        rebuilt.Show(next with { ContextLevel = Level(0.5) }, ink, true);
        Check(rebuilt.Sweep?.Duration == 0.5, "Ordinary level changes use one half-second sweep");
        double now = TaskProgressRing.Now;
        rebuilt.Show(next with { Symbol = "checkmark.circle", ProgressMode = "done", ProgressFraction = 1 }, ink, true);
        Check(rebuilt.Sweep is { From: 1, Duration: 0.5 } ended && ended.Start >= now + TaskStatusIcon.FillDuration - 0.01,
            "The waterline on an ended disc waits for the inward fill");
        await PresentationWait.UntilAsync(() => Near(rebuilt.LevelHeightShown, TaskStatusIcon.LevelHeight(0.25)) && !rebuilt.LevelMoving, "The settled level releases its clock");
        var pending = working with { Id = Guid.NewGuid().ToString(), CompactingSince = since };
        rebuilt.Show(pending, ink, true);
        Check(rebuilt.Ring.CometStill && rebuilt.Ring.Loops == "" && Near(rebuilt.Ring.DisplayFraction, 0), "A pending ring holds a static circle");
    }
}
