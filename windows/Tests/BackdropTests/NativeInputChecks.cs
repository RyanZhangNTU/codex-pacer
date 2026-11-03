using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using CodexPacer.Windows;

// A native input regression limited to this process's protected synthetic
// island and its owned scene. It never dispatches into a foreign HWND.
internal static class NativeInputChecks
{
    internal static async Task Run(IslandWindow island, ProtectedScene scene, string output)
    {
        if (!GetCursorPos(out var original)) throw new System.ComponentModel.Win32Exception();
        var content = new WindowInteropHelper(island).Handle;
        var pin = (Button)island.FindName("PinButton");
        try
        {
            var bounds = island.VisibleScreenBounds;
            var outside = new ScreenNative.Point { X = (int)bounds.Left + 1, Y = (int)bounds.Bottom - 1 };
            int Count()
            {
                string file = Path.Combine(output, "clicks.json");
                if (!File.Exists(file)) return 0;
                using var data = JsonDocument.Parse(File.ReadAllBytes(file)); return data.RootElement.GetProperty("count").GetInt32();
            }
            int before = Count();
            await Click(outside, scene.Handle, "outside");
            if (Count() != before + 1) throw new InvalidOperationException("The scene did not receive exactly one outside click.");
            string old = AutomationProperties.GetName(pin);
            var center = pin.PointToScreen(new Point(pin.ActualWidth / 2, pin.ActualHeight / 2));
            await Click(new() { X = (int)center.X, Y = (int)center.Y }, content, "inside");
            if (AutomationProperties.GetName(pin) == old) throw new InvalidOperationException("The real Pin button did not toggle.");
            if (island.IsActive || ScreenNative.GetForegroundWindow() == content || ScreenNative.GetForegroundWindow() == island.BackdropWindowHandle)
                throw new InvalidOperationException("A normal input click activated the island.");
            File.WriteAllText(Path.Combine(output, "input.json"), JsonSerializer.Serialize(new { outsideClicks = Count() - before, pinToggled = true,
                noActivation = true, glass = island.GlassVisible, scale = System.Windows.Media.VisualTreeHelper.GetDpi(island).DpiScaleX,
                monitors = System.Windows.Forms.Screen.AllScreens.Length }));
        }
        finally { Move(original); }

        async Task Click(ScreenNative.Point point, IntPtr expected, string name)
        {
            // The screenshot guard checks the complete crop before input too.
            scene.Capture(Path.Combine(output, "before-" + name + ".png"), ProtectedScene.Surfaces(island));
            if (ScreenNative.WindowFromPoint(point) != expected) throw new InvalidOperationException("Input target was not an owned synthetic HWND.");
            Move(point); await Task.Delay(80);
            if (ScreenNative.WindowFromPoint(point) != expected) throw new InvalidOperationException("The input target changed after pointer movement.");
            Send([Mouse(0, 0, 0x0002), Mouse(0, 0, 0x0004)]); await Task.Delay(150);
        }
    }
    private static void Move(ScreenNative.Point point)
    {
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        Send([Mouse((int)Math.Round((point.X - left) * 65535d / (width - 1)), (int)Math.Round((point.Y - top) * 65535d / (height - 1)), 0x8000 | 0x4000 | 0x0001)]);
    }
    private static Input Mouse(int x, int y, uint flags) => new() { Type = 0, Data = new() { Mouse = new() { X = x, Y = y, Flags = flags } } };
    private static void Send(Input[] input) { if (SendInput((uint)input.Length, input, Marshal.SizeOf<Input>()) != input.Length) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
    [StructLayout(LayoutKind.Sequential)] private struct Input { internal uint Type; internal Payload Data; }
    [StructLayout(LayoutKind.Explicit)] private struct Payload { [FieldOffset(0)] internal MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { internal int X, Y; internal uint Data, Flags, Time; internal UIntPtr Extra; }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out ScreenNative.Point point);
}
