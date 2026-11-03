using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexPacer.Windows;

internal sealed class SyntheticScene : FrameworkElement
{
    internal const int ThemeMessage = 0x85A2;
    private bool dark;
    protected override void OnRender(DrawingContext drawing)
    {
        drawing.DrawRectangle(new SolidColorBrush(dark ? Color.FromRgb(23, 30, 48) : Color.FromRgb(236, 242, 252)), null, new Rect(RenderSize));
        Color[] colors = dark ? new[] { Color.FromRgb(33, 73, 106), Color.FromRgb(77, 48, 112), Color.FromRgb(33, 94, 81) }
            : new[] { Color.FromRgb(92, 179, 218), Color.FromRgb(182, 141, 218), Color.FromRgb(97, 197, 164) };
        for (int i = 0; i < 12; i++)
        {
            var brush = new SolidColorBrush(colors[i % colors.Length]);
            drawing.DrawRectangle(brush, null, new Rect(i * ActualWidth / 12, 0, ActualWidth / 24, ActualHeight));
        }
        var ink = new SolidColorBrush(dark ? Color.FromRgb(185, 200, 220) : Color.FromRgb(70, 86, 112));
        for (int y = 70; y < ActualHeight; y += 70) drawing.DrawRectangle(ink, null, new Rect(0, y, ActualWidth, 2));
    }
    internal static void Show(string output)
    {
        var canvas = new SyntheticScene();
        var window = new Window { Title = "Pacer synthetic surface scene", WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            Width = Math.Min(1000, SystemParameters.PrimaryScreenWidth - 40), Height = Math.Min(800, SystemParameters.PrimaryScreenHeight - 40),
            Left = Math.Max(0, (SystemParameters.PrimaryScreenWidth - Math.Min(1000, SystemParameters.PrimaryScreenWidth - 40)) / 2), Top = 0,
            ShowActivated = false, ShowInTaskbar = false, Topmost = true, Content = canvas, Background = Brushes.White };
        WindowRendering.Prepare(window);
        int clicks = 0;
        window.PreviewMouseDown += (_, _) => File.WriteAllText(Path.Combine(output, "clicks.json"), JsonSerializer.Serialize(new { count = ++clicks }));
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            var source = HwndSource.FromHwnd(hwnd)!;
            source.AddHook((IntPtr h, int message, IntPtr wparam, IntPtr lparam, ref bool handled) =>
            {
                if (message == 0x0021) { handled = true; return new IntPtr(3); }
                if (message == ThemeMessage) { canvas.dark = wparam != IntPtr.Zero; canvas.InvalidateVisual(); handled = true; }
                return IntPtr.Zero;
            });
        };
        window.ContentRendered += (_, _) => File.WriteAllText(Path.Combine(output, "scene.json"), JsonSerializer.Serialize(new { pid = Environment.ProcessId, hwnd = new WindowInteropHelper(window).Handle.ToInt64() }));
        window.Closed += (_, _) => Application.Current.Shutdown(); window.Show();
    }
}

internal sealed class ProtectedScene : IAsyncDisposable
{
    private readonly Process process;
    private readonly OwnedJob job;
    internal IntPtr Handle { get; }
    internal int ProcessId => process.Id;
    private ProtectedScene(Process process, IntPtr handle, OwnedJob job) { this.process = process; Handle = handle; this.job = job; }
    internal static async Task<ProtectedScene> Start(string output)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        start.ArgumentList.Add("scene"); start.ArgumentList.Add(output);
        var job = new OwnedJob();
        Process process;
        try { process = Process.Start(start) ?? throw new InvalidOperationException("The synthetic scene did not start."); }
        catch { job.Dispose(); throw; }
        try
        {
            job.Attach(process);
            string ready = Path.Combine(output, "scene.json");
            var clock = Stopwatch.StartNew();
            while (!File.Exists(ready) && !process.HasExited && clock.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(40);
            using var data = JsonDocument.Parse(File.ReadAllBytes(ready));
            int pid = data.RootElement.GetProperty("pid").GetInt32(); var hwnd = new IntPtr(data.RootElement.GetProperty("hwnd").GetInt64());
            ScreenNative.GetWindowThreadProcessId(hwnd, out uint actual);
            if (pid != process.Id || actual != pid || !ScreenNative.IsWindowVisible(hwnd)) throw new InvalidOperationException("Unexpected synthetic scene owner.");
            return new(process, hwnd, job);
        }
        catch { job.Dispose(); if (!process.HasExited) process.Kill(); process.Dispose(); throw; }
    }
    internal void Theme(bool dark) => ScreenNative.SendMessage(Handle, SyntheticScene.ThemeMessage, dark ? new IntPtr(1) : IntPtr.Zero, IntPtr.Zero);
    internal ScreenNative.Bounds Bounds => ScreenNative.Read(Handle);
    internal static IntPtr[] Surfaces(IslandWindow island)
    {
        IntPtr Orbit(string name) => typeof(ActivityBadge).GetProperty("RotationScheduling", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.GetValue((ActivityBadge)island.FindName(name)) is ValueTuple<bool, bool, long, IntPtr> value ? value.Item4 : IntPtr.Zero;
        return [new WindowInteropHelper(island).Handle, island.BackdropWindowHandle, Orbit("Badge"), Orbit("StripBadge")];
    }
    internal void Capture(string path, params IntPtr[] allowed)
    {
        var bounds = Bounds;
        // Both checks precede saving. Reject foreign windows above the opaque
        // scene; no desktop image is emitted or written after a failed guard.
        Guard(bounds, allowed);
        using var pixels = new System.Drawing.Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var graphics = System.Drawing.Graphics.FromImage(pixels)) graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, new System.Drawing.Size(bounds.Width, bounds.Height));
        Guard(bounds, allowed);
        pixels.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    private void Guard(ScreenNative.Bounds capture, IntPtr[] allowed)
    {
        bool sceneSeen = false, foreign = false;
        ScreenNative.EnumWindows((hwnd, _) =>
        {
            if (hwnd == Handle) { sceneSeen = true; return false; }
            if (!ScreenNative.IsWindowVisible(hwnd) || allowed.Contains(hwnd)) return true;
            if (ScreenNative.DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var rectangle = ScreenNative.Read(hwnd);
            if (rectangle.Width > 0 && rectangle.Height > 0 && rectangle.Intersects(capture)) { foreign = true; return false; }
            return true;
        }, IntPtr.Zero);
        ScreenNative.GetWindowThreadProcessId(Handle, out uint owner);
        if (!sceneSeen || foreign || owner != process.Id || process.HasExited || !ScreenNative.IsWindowVisible(Handle))
            throw new InvalidOperationException("Screenshot rejected: the synthetic scene does not fully protect its capture rectangle.");
    }
    public async ValueTask DisposeAsync()
    {
        if (!process.HasExited) ScreenNative.PostMessage(Handle, 0x0010, IntPtr.Zero, IntPtr.Zero);
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (TimeoutException) { if (!process.HasExited) process.Kill(); }
        job.Dispose(); process.Dispose();
    }
}

internal static class ScreenNative
{
    [StructLayout(LayoutKind.Sequential)] internal struct Bounds
    {
        internal int Left, Top, Right, Bottom;
        internal int Width => Right - Left;
        internal int Height => Bottom - Top;
        internal bool Intersects(Bounds other) => Left < other.Right && Right > other.Left && Top < other.Bottom && Bottom > other.Top;
    }
    internal static Bounds Read(IntPtr hwnd) { if (!GetWindowRect(hwnd, out var bounds)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); return bounds; }
    internal delegate bool WindowCallback(IntPtr hwnd, IntPtr value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(WindowCallback callback, IntPtr value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out Bounds bounds);
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out int value, int size);
    [DllImport("dwmapi.dll")] internal static extern int DwmFlush();
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] internal static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] internal struct Point { internal int X, Y; }
    [DllImport("user32.dll")] internal static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
}
