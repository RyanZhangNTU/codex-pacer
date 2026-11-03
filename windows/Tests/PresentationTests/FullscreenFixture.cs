using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

// An independent opaque app window, with no task data or keyboard logging.
internal static class FullscreenFixture
{
    internal static int Run()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        int result = 1;
        app.Startup += async (_, _) =>
        {
            Window? window = null;
            using var topology = new WindowsDisplayTopology(action => app.Dispatcher.BeginInvoke(action));
            try
            {
                var display = topology.Current.FirstOrDefault(value => value.Primary) ?? throw new InvalidOperationException("No QA display");
                var bounds = display.Bounds;
                window = new Window { WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Topmost = true,
                    ShowActivated = false, ShowInTaskbar = true, Title = "Pacer display QA", Background = new SolidColorBrush(Color.FromRgb(34, 42, 54)),
                    Content = new TextBlock { Text = "Pacer display QA", Foreground = Brushes.White, FontSize = 28,
                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
                WindowRendering.Prepare(window); window.Show();
                IntPtr hwnd = new WindowInteropHelper(window).Handle;
                long style = GetWindowLongPtr(hwnd, -20).ToInt64();
                SetWindowLongPtr(hwnd, -20, new IntPtr((style | 0x08000000L | 0x40000L) & ~0x80L));
                void Place()
                {
                    double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
                    NativeWindowBounds.Apply(window, new(bounds.Left / scale, bounds.Top / scale,
                        (bounds.Right - bounds.Left) / scale, (bounds.Bottom - bounds.Top) / scale));
                    _ = NativeWindowBounds.RaiseWithoutActivation(window);
                }
                Place(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                Console.WriteLine(JsonSerializer.Serialize(new { type = "ready", handle = hwnd.ToInt64() }));
                while (await Console.In.ReadLineAsync() is string line)
                {
                    if (line.Length > 2048) throw new InvalidOperationException("Oversized QA command");
                    using var data = JsonDocument.Parse(line);
                    string command = data.RootElement.GetProperty("command").GetString()!;
                    if (command == "quit") break;
                    if (command == "hide") window.Hide();
                    else if (command == "minimize") window.WindowState = WindowState.Minimized;
                    else if (command is "show" or "bounds")
                    {
                        if (command == "bounds")
                        {
                            var p = data.RootElement;
                            var next = new ScreenRectangle(p.GetProperty("left").GetInt32(), p.GetProperty("top").GetInt32(), p.GetProperty("right").GetInt32(), p.GetProperty("bottom").GetInt32());
                            if (!next.Valid || !display.Bounds.Contains(next)) throw new InvalidOperationException("QA bounds exceed the synthetic display");
                            bounds = next;
                        }
                        window.WindowState = WindowState.Normal; window.Show(); Place();
                    }
                    else throw new InvalidOperationException("Unknown QA command");
                    await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                    Console.WriteLine("{\"type\":\"ack\"}");
                }
                result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine("Fullscreen QA failed: " + error.GetType().Name); }
            finally { window?.Close(); app.Shutdown(); }
        };
        app.Run(); return result;
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
}
