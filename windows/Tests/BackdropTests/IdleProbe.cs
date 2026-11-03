using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class IdleProbe
{
    internal static async Task Run(string output)
    {
        await using var engine = new EngineClient(); ShellProjection.Client = engine;
        // Keep the UI input immutable. Demo maintenance can rebuild numeric
        // wallet aggregates, even with a frozen wall clock. A separate client
        // still answers real shared presentation queries.
        await using var display = new EngineClient();
        string? side = Environment.GetEnvironmentVariable("PACER_IDLE_SIDE");
        Func<(MotionBounds Screen, MotionBounds WorkArea)>? viewport = side is "left" or "right" ? () =>
        {
            var screen = System.Windows.Forms.Screen.PrimaryScreen!; double scale = System.Windows.Forms.Screen.PrimaryScreen!.Bounds.Width / SystemParameters.PrimaryScreenWidth;
            var area = screen.Bounds; var work = screen.WorkingArea; double width = area.Width / scale / 2;
            double x = area.X / scale + (side == "right" ? width : 0);
            return (new(x, area.Y / scale, width, area.Height / scale), new(x, work.Y / scale, width, work.Height / scale));
        } : null;
        var window = new IslandWindow(display, true, false, animationOverride: true, screenGeometry: viewport) { IsHitTestVisible = false, ShowActivated = false };
        Window? cover = null; string state = "collapsed", ablation = "none", appearance = "classic";
        long frames = 0, renders = 0, snapshots = 0;
        window.FrameApplied += _ => frames++;
        DispatcherHookEventHandler posted = (_, e) => { if (e.Operation.Priority == DispatcherPriority.Render) Interlocked.Increment(ref renders); };
        Application.Current.Dispatcher.Hooks.OperationPosted += posted;
        void Ablate()
        {
            if (engine.LatestSnapshot?.Presentation?.Header is not EngineHeader header) return;
            if (ablation is "badge" or "all" or "collected")
                foreach (string name in new[] { "Badge", "StripBadge" }) ((ActivityBadge)window.FindName(name)).Update(header, false);
            if (ablation is "quota" or "all" or "collected")
                foreach (string name in new[] { "QuotaLabel", "StripQuota" }) ((AlternatingQuotaText)window.FindName(name)).Stop();
            if (ablation == "collected") { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); }
        }
        engine.Snapshot += _ => { snapshots++; if (ablation != "none") window.Dispatcher.BeginInvoke(Ablate, DispatcherPriority.ContextIdle); };
        void Reply(object value) => Console.WriteLine(JsonSerializer.Serialize(value));
        bool Covered()
        {
            if (cover == null || !cover.IsVisible) return false;
            bool seen = false, valid = true; IntPtr shield = new WindowInteropHelper(cover).Handle;
            var surfaces = ProtectedScene.Surfaces(window);
            ScreenNative.EnumWindows((hwnd, _) =>
            {
                if (hwnd == shield) seen = true;
                if (Array.IndexOf(surfaces, hwnd) >= 0 && ScreenNative.IsWindowVisible(hwnd) && !seen) valid = false;
                return true;
            }, IntPtr.Zero);
            return seen && valid;
        }
        try
        {
            window.ApplyPreferences(new() { IslandAppearance = "classic", DisplayMode = "notch" }); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.ReceiveSnapshot(engine.LatestSnapshot!);
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            var ready = new { type = "ready", pid = Environment.ProcessId, enginePid = engine.ProcessId, processors = Environment.ProcessorCount };
            File.WriteAllText(Path.Combine(output, "ready.json"), JsonSerializer.Serialize(ready)); Reply(ready);
            using var input = new StreamReader(Console.OpenStandardInput());
            using var process = Process.GetCurrentProcess(); using var child = Process.GetProcessById(engine.ProcessId!.Value);
            while (await input.ReadLineAsync() is string line)
            {
                if (line.Length > 1024) throw new InvalidDataException("Diagnostic command too large.");
                using var data = JsonDocument.Parse(line); var command = data.RootElement.GetProperty("command").GetString();
                if (command == "quit") { Reply(new { type = "stopped" }); break; }
                if (command == "surface")
                {
                    appearance = data.RootElement.GetProperty("value").GetString()!;
                    if (appearance is not ("classic" or "liquidGlass")) throw new InvalidDataException("Unknown diagnostic surface.");
                    window.ApplyPreferences(new() { IslandAppearance = appearance, DisplayMode = "notch" }); await window.WaitForPresentationAsync();
                    if (appearance == "liquidGlass" && !window.GlassVisible) throw new InvalidOperationException("Material CPU checks require actual composition glass.");
                    Reply(new { type = "surface", appearance }); continue;
                }
                if (command == "inspect")
                {
                    var clocks = new List<string>(); var seen = new HashSet<DependencyObject>();
                    void Visit(DependencyObject node)
                    {
                        if (!seen.Add(node)) return;
                        var properties = node.GetLocalValueEnumerator();
                        var known = new HashSet<DependencyProperty>();
                        foreach (var field in node.GetType().GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.FlattenHierarchy))
                            if (field.FieldType == typeof(DependencyProperty) && field.GetValue(null) is DependencyProperty property) known.Add(property);
                        foreach (var property in known)
                            if (DependencyPropertyHelper.GetValueSource(node, property).IsAnimated) clocks.Add(node.GetType().Name + "." + property.Name);
                        while (properties.MoveNext())
                        {
                            var property = properties.Current.Property;
                            if (node.GetValue(property) is Freezable child) Visit(child);
                        }
                        if (node is Visual)
                            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) Visit(VisualTreeHelper.GetChild(node, i));
                    }
                    Visit(window); Reply(new { type = "inspect", clocks }); continue;
                }
                if (command == "state")
                {
                    state = data.RootElement.GetProperty("value").GetString()!;
                    if (state is not ("collapsed" or "expanded" or "hidden" or "covered")) throw new InvalidDataException("Unknown diagnostic state.");
                    cover?.Close(); cover = null; window.Show();
                    if (state is "expanded" or "covered") window.Reveal(); else window.CollapseForAutomation();
                    await window.WaitForPresentationAsync();
                    if (state == "hidden") window.Hide();
                    if (state == "covered")
                    {
                        var monitor = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle).Bounds;
                        double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
                        cover = new Window { WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowActivated = false, ShowInTaskbar = false,
                            Topmost = true, Left = monitor.Left / scale, Top = monitor.Top / scale, Width = monitor.Width / scale, Height = monitor.Height / scale, Background = Brushes.Black };
                        WindowRendering.Prepare(cover); cover.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                        if (!Covered())
                            throw new InvalidOperationException("The synthetic fullscreen cover did not obscure the island.");
                    }
                    Ablate(); Reply(new { type = "state", state }); continue;
                }
                if (command == "ablation")
                {
                    ablation = data.RootElement.GetProperty("value").GetString()!;
                    if (ablation is not ("none" or "badge" or "quota" or "all" or "collected")) throw new InvalidDataException("Unknown ablation.");
                    if (engine.LatestSnapshot is { } latest) window.ReceiveSnapshot(latest);
                    await window.WaitForPresentationAsync(); Ablate(); Reply(new { type = "ablation", ablation }); continue;
                }
                if (command == "sample")
                {
                    int seconds = data.RootElement.GetProperty("seconds").GetInt32();
                    if (seconds is < 5 or > 600) throw new InvalidDataException("Invalid sample duration.");
                    void ConfirmDisplay()
                    {
                        IntPtr desktop = OpenInputDesktop(0, false, 0x0100);
                        if (desktop == IntPtr.Zero) throw new InvalidOperationException("The input desktop is unavailable; this is not a confirmed UI sample.");
                        CloseDesktop(desktop);
                        if (state == "hidden") { if (window.IsVisible) throw new InvalidOperationException("The idle window is not hidden."); return; }
                        if (state == "covered")
                        {
                            if (!Covered()) throw new InvalidOperationException("The synthetic fullscreen cover is not above every island surface.");
                            return;
                        }
                        var visible = window.VisibleScreenBounds;
                        var point = new ScreenNative.Point { X = (int)(visible.X + visible.Width / 2), Y = (int)(visible.Y + visible.Height / 2) };
                        if (visible.IsEmpty || ScreenNative.WindowFromPoint(point) != new WindowInteropHelper(window).Handle)
                            throw new InvalidOperationException("The measured island is obscured; this is not a confirmed visible sample.");
                    }
                    ConfirmDisplay();
                    double Cpu(Process value) { value.Refresh(); return value.TotalProcessorTime.TotalSeconds; }
                    double before = Cpu(process), engineBefore = Cpu(child);
                    var hostBefore = Times(); long frameBefore = frames, renderBefore = renders, snapshotBefore = snapshots;
                    var clock = Stopwatch.StartNew(); await Task.Delay(TimeSpan.FromSeconds(seconds));
                    double wall = clock.Elapsed.TotalSeconds, cpu = Cpu(process) - before, engineCpu = Cpu(child) - engineBefore;
                    var hostAfter = Times(); double hostTime = hostAfter.Kernel - hostBefore.Kernel + hostAfter.User - hostBefore.User;
                    ConfirmDisplay();
                    var badge = (ActivityBadge)window.FindName("Badge");
                    var badgeValue = typeof(ActivityBadge).GetProperty("RotationScheduling", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.GetValue(badge);
                    var badgeInfo = badgeValue is ValueTuple<bool, bool, long, IntPtr> info ? info : default;
                    var result = new { type = "sample", state, ablation, appearance, wallSeconds = wall, shellCpuSeconds = cpu,
                        shellOneCorePercent = cpu / wall * 100, shellHostPercent = cpu / wall / Environment.ProcessorCount * 100,
                        engineCpuSeconds = engineCpu, engineOneCorePercent = engineCpu / wall * 100,
                        engineHostPercent = engineCpu / wall / Environment.ProcessorCount * 100,
                        wholeMachineBusyPercent = 100 * (hostTime - (hostAfter.Idle - hostBefore.Idle)) / hostTime,
                        frames = frames - frameBefore, renderOperations = renders - renderBefore, snapshots = snapshots - snapshotBefore,
                        composedBadge = badgeValue == null ? (bool?)null : badgeInfo.Item1, badgeFallback = badgeValue == null ? (bool?)null : badgeInfo.Item2, immutableDisplay = true,
                        displayConfirmed = true,
                        processors = Environment.ProcessorCount, scale = VisualTreeHelper.GetDpi(window).DpiScaleX };
                    File.AppendAllText(Path.Combine(output, "samples.jsonl"), JsonSerializer.Serialize(result) + Environment.NewLine); Reply(result); continue;
                }
                throw new InvalidDataException("Unknown diagnostic command.");
            }
        }
        finally { cover?.Close(); Application.Current.Dispatcher.Hooks.OperationPosted -= posted; window.AllowClose = true; window.Close(); ShellProjection.Client = null; }
    }
    private readonly record struct CpuTimes(ulong Idle, ulong Kernel, ulong User);
    private static CpuTimes Times() { if (!GetSystemTimes(out ulong idle, out ulong kernel, out ulong user)) throw new System.ComponentModel.Win32Exception(); return new(idle, kernel, user); }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(IntPtr desktop);
}
