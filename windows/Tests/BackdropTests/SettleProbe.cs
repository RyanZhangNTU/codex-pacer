using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CodexPacer.Windows;

/// Samples the composed screen over the synthetic scene while the island opens
/// and closes, and reports every sample after the last applied frame whose
/// island outline differs from the settled one. A settled island must not move.
/// PACER_SETTLE_FRAMES=1 also saves the synthetic frames around a displaced sample.
internal static class SettleProbe
{
    internal static async Task Run(string output)
    {
        await using var scene = await ProtectedScene.Start(output);
        var area = scene.Bounds;
        var sampler = new ScreenSampler(area);
        await sampler.TakeReference();
        await using var engine = new EngineClient(); ShellProjection.Client = engine;
        var window = new IslandWindow(engine, true, false, animationOverride: true) { ShowActivated = false, IsHitTestVisible = false };
        double finished = 0; bool armed = false;
        window.FrameApplied += frame =>
        {
            if (!armed || !frame.Finished || finished != 0) return;
            finished = ScreenSampler.Now(); sampler.FreezeAt = finished + 0.06;
        };
        var results = new List<object>(); var failures = new List<string>();
        try
        {
            window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.Reveal(); await window.WaitForPresentationAsync();
            foreach (var (style, mode) in new[] { ("classic", "notch"), ("liquidGlass", "notch"), ("liquidGlass", "floating") })
            {
                window.ApplyPreferences(new() { IslandAppearance = style, DisplayMode = mode }); await window.WaitForPresentationAsync();
                await Task.Delay(300);
                for (int index = 0; index < 8; index++)
                {
                    bool opening = index % 2 == 1;
                    finished = 0; armed = true; sampler.Start();
                    double started = ScreenSampler.Now();
                    if (opening) window.Reveal(); else window.CollapseForAutomation();
                    await window.WaitForPresentationAsync();
                    await Task.Delay(600);
                    var samples = sampler.Stop(); armed = false;
                    var settled = samples[^1].Box;
                    var after = samples.Where(sample => sample.At > finished).ToArray();
                    var displaced = after.Where(sample => sample.Box.Distance(settled) > 1).ToArray();
                    string name = $"{style}-{mode}-{index}-{(opening ? "open" : "close")}";
                    if (displaced.Length > 0 && Environment.GetEnvironmentVariable("PACER_SETTLE_FRAMES") == "1")
                    {
                        // Synthetic scene and reference fixture only; a few frames around the first displaced sample.
                        int first = Array.IndexOf(samples, displaced[0]);
                        for (int frame = Math.Max(0, first - 2); frame <= Math.Min(samples.Length - 1, first + 2); frame++)
                            sampler.Save(samples[frame], Path.Combine(output, $"{name}-{frame - first:+0;-0;0}.png"), settled);
                    }
                    results.Add(new
                    {
                        style, mode, transition = opening ? "open" : "close", samples = samples.Length, samplesAfterFinish = after.Length,
                        finishMs = Math.Round((finished - started) * 1000), settled = settled.ToString(), displaced = displaced.Length,
                        worstPx = displaced.Length == 0 ? 0 : displaced.Max(sample => sample.Box.Distance(settled)),
                        displacedAtMs = displaced.Select(sample => Math.Round((sample.At - finished) * 1000)).ToArray(),
                        boxes = displaced.Select(sample => sample.Box.ToString()).Distinct().ToArray(),
                        surface = $"{window.SurfaceBounds.X:0.#},{window.SurfaceBounds.Y:0.#} {window.SurfaceBounds.Width:0.#}x{window.SurfaceBounds.Height:0.#}"
                    });
                    File.WriteAllText(Path.Combine(output, "settle.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
                    // Two pixels allow the spring's last antialiased edge, still on screen when the final frame is applied.
                    if (displaced.Any(sample => sample.Box.Distance(settled) > 2)) failures.Add(name);
                    await Task.Delay(200);
                }
            }
            if (failures.Count > 0) throw new InvalidOperationException("The island moved after its transition settled: " + string.Join(", ", failures));
        }
        finally { window.AllowClose = true; window.Close(); ShellProjection.Client = null; }
    }
}

/// Copies the composed screen rectangle in a loop on its own thread and keeps
/// only the outline of pixels that differ from the scene alone. No image is kept.
internal sealed class ScreenSampler(ScreenNative.Bounds area)
{
    internal readonly record struct Box(int Left, int Top, int Right, int Bottom)
    {
        internal int Distance(Box other) => Math.Max(Math.Max(Math.Abs(Left - other.Left), Math.Abs(Top - other.Top)),
            Math.Max(Math.Abs(Right - other.Right), Math.Abs(Bottom - other.Bottom)));
        public override string ToString() => $"{Left},{Top}-{Right},{Bottom}";
    }
    internal readonly record struct Sample(double At, Box Box, int Index);
    private int[]? reference;
    private Thread? thread;
    private volatile bool running;
    private List<Sample> samples = new();
    // The last frames up to FreezeAt, for a look at the samples around the settle.
    private readonly int[][] ring = Enumerable.Range(0, 12).Select(_ => new int[area.Width * area.Height]).ToArray();
    private readonly int[] ringIndex = new int[12];
    private long freezeAt = BitConverter.DoubleToInt64Bits(double.MaxValue);
    internal double FreezeAt { get => BitConverter.Int64BitsToDouble(Interlocked.Read(ref freezeAt)); set => Interlocked.Exchange(ref freezeAt, BitConverter.DoubleToInt64Bits(value)); }
    internal void Save(Sample sample, string path, Box settled)
    {
        int slot = Array.IndexOf(ringIndex, sample.Index);
        if (slot < 0) return;
        int left = Math.Max(0, Math.Min(sample.Box.Left, settled.Left) - 30), top = Math.Max(0, Math.Min(sample.Box.Top, settled.Top) - 30);
        int right = Math.Min(area.Width - 1, Math.Max(sample.Box.Right, settled.Right) + 30), bottom = Math.Min(area.Height - 1, Math.Max(sample.Box.Bottom, settled.Bottom) + 30);
        using var image = new System.Drawing.Bitmap(right - left + 1, bottom - top + 1, System.Drawing.Imaging.PixelFormat.Format32bppRgb);
        var pixels = ring[slot];
        for (int y = top; y <= bottom; y++)
            for (int x = left; x <= right; x++)
                image.SetPixel(x - left, y - top, System.Drawing.Color.FromArgb(pixels[y * area.Width + x] | unchecked((int)0xFF000000)));
        image.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    internal static double Now() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    internal Task TakeReference()
    {
        var done = new TaskCompletionSource();
        var worker = new Thread(() =>
        {
            try { using var grabber = new Grabber(area); grabber.Grab(); reference = grabber.Pixels.ToArray(); done.SetResult(); }
            catch (Exception error) { done.SetException(error); }
        }) { IsBackground = true };
        worker.Start(); return done.Task;
    }
    internal void Start()
    {
        samples = new(); running = true; FreezeAt = double.MaxValue; Array.Fill(ringIndex, -1);
        thread = new Thread(() =>
        {
            using var grabber = new Grabber(area);
            int slot = 0;
            while (running)
            {
                double at = Now(); grabber.Grab();
                if (at <= FreezeAt) { Array.Copy(grabber.Pixels, ring[slot], grabber.Pixels.Length); ringIndex[slot] = samples.Count; slot = (slot + 1) % ring.Length; }
                samples.Add(new(at, Outline(grabber.Pixels), samples.Count));
            }
        }) { IsBackground = true, Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }
    internal Sample[] Stop() { running = false; thread?.Join(); return samples.ToArray(); }
    private Box Outline(int[] pixels)
    {
        int width = area.Width, height = area.Height, left = width, top = height, right = -1, bottom = -1;
        var scene = reference!;
        for (int y = 0; y < height; y += 2)
        {
            int row = y * width;
            for (int x = 0; x < width; x += 2)
            {
                int a = pixels[row + x], b = scene[row + x];
                if (a == b) continue;
                int red = Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)), green = Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)), blue = Math.Abs((a & 255) - (b & 255));
                if (Math.Max(red, Math.Max(green, blue)) < 40) continue;
                if (x < left) left = x; if (x > right) right = x; if (y < top) top = y; if (y > bottom) bottom = y;
            }
        }
        return right < 0 ? new(0, 0, 0, 0) : new(left, top, right, bottom);
    }
    private sealed class Grabber : IDisposable
    {
        private readonly ScreenNative.Bounds area;
        private readonly IntPtr screen, memory, bitmap, previous, bits;
        internal readonly int[] Pixels;
        internal Grabber(ScreenNative.Bounds area)
        {
            this.area = area; Pixels = new int[area.Width * area.Height];
            screen = GetDC(IntPtr.Zero); memory = CreateCompatibleDC(screen);
            var info = new BitmapInfo { Size = Marshal.SizeOf<BitmapInfo>(), Width = area.Width, Height = -area.Height, Planes = 1, BitCount = 32 };
            bitmap = CreateDIBSection(memory, ref info, 0, out bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero) throw new InvalidOperationException("The sampling bitmap could not be created.");
            previous = SelectObject(memory, bitmap);
        }
        internal void Grab()
        {
            if (!BitBlt(memory, 0, 0, area.Width, area.Height, screen, area.Left, area.Top, 0x00CC0020)) throw new InvalidOperationException("The screen could not be sampled.");
            Marshal.Copy(bits, Pixels, 0, Pixels.Length);
        }
        public void Dispose() { SelectObject(memory, previous); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen); }
        [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo
        {
            internal int Size, Width, Height; internal short Planes, BitCount; internal int Compression, SizeImage, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant, Colors;
        }
        [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
        [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(IntPtr value);
        [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);
    }
}
