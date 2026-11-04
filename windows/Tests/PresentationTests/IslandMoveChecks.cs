using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using CodexPacer.Windows;

internal static class IslandMoveChecks
{
    internal static async Task Run(string surface)
    {
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
        var window = new IslandWindow(engine, true, false, animationOverride: false) { AllowClose = true };
        var original = System.Windows.Forms.Cursor.Position;
        int writes = 0;
        var session = new PreferencesSession(new() { DisplayMode = "notch", IslandAppearance = surface },
            _ => throw new InvalidOperationException("A placement must not reconfigure the engine"), _ => { writes++; return true; });
        window.SaveIslandPlacement = edit => session.ChangeAsync(edit);
        session.Changed += window.ApplyPreferences;
        bool pressed = false;
        try
        {
            window.ApplyPreferences(session.Current); window.Show();
            await window.WaitForPresentationAsync();
            var monitor = window.SelectedDisplay.Display ?? throw new InvalidOperationException("The interaction check needs an interactive monitor.");
            var work = monitor.Work;
            var hwnd = new WindowInteropHelper(window).Handle;
            var pin = (Button)window.FindName("PinButton");
            string originalPin = AutomationProperties.GetName(pin);
            await Press(); Up();
            await PresentationWait.UntilAsync(() => AutomationProperties.GetName(pin) != originalPin, "A click without a drag still pins the island");
            await Press(); Up();
            await PresentationWait.UntilAsync(() => AutomationProperties.GetName(pin) == originalPin, "A second click still unpins it");
            Check(writes == 0 && !window.IsActive, "Clicking and hovering neither save a position nor activate the island");

            int midX = (work.Left + work.Right) / 2, midY = (work.Top + work.Bottom) / 2;
            await Drag(midX, midY, IslandEdge.Free);
            Check(session.Current.DisplayMode == "floating" && session.Current.IslandPlacement?.Edge == IslandEdge.Free,
                "Dragging from Notch switches to Free Move and saves an interior position");
            foreach (var (edge, x, y) in new[]
            {
                (IslandEdge.Left, work.Left + 1, midY), (IslandEdge.Right, work.Right - 2, midY),
                (IslandEdge.Top, midX, work.Top + 1), (IslandEdge.Bottom, midX, work.Bottom - 2)
            })
            {
                await Drag(x, y, edge);
                var bounds = window.VisibleScreenBounds;
                double gap = edge switch
                {
                    IslandEdge.Top => bounds.Top - work.Top, IslandEdge.Bottom => work.Bottom - bounds.Bottom,
                    IslandEdge.Left => bounds.Left - work.Left, _ => work.Right - bounds.Right
                };
                Check(Math.Abs(gap) <= 2, "The visible bar meets the selected work-area edge: " + edge + ", gap=" + gap);
            }
            Move(midX, midY);
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            var closed = window.VisibleScreenBounds;
            window.Reveal(); await window.WaitForPresentationAsync();
            Check(window.VisibleScreenBounds.Top < closed.Top && Math.Abs(window.VisibleScreenBounds.Bottom - closed.Bottom) <= 2,
                $"The bottom bar opens upward without moving its edge (closed={closed}, open={window.VisibleScreenBounds})");
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            var previous = session.Current.IslandPlacement;
            int before = writes;
            var menu = (MenuItem)window.FindName("MoveMenu");
            menu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            await KeyInput(Key.Left); await KeyInput(Key.Escape);
            Check(writes == before && session.Current.IslandPlacement == previous, "Esc cancels keyboard movement without saving");
            menu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            await KeyInput(Key.Left); await KeyInput(Key.Enter);
            await PresentationWait.UntilAsync(() => writes == before + 1 && session.Current.IslandPlacement != previous,
                "The keyboard move commits once on Enter");
            Console.WriteLine("PASS island position (" + (window.GlassVisible ? "Glass" : surface) +
                "): native drag, preview, four edges, click, bottom expansion and keyboard commit/cancel");

            async Task KeyInput(Key key)
            {
                await PresentationWait.UntilAsync(() => GetForegroundWindow() == hwnd && Keyboard.FocusedElement is Button button &&
                    (button.Name == "HeaderAction" || button.Name == "StripAction"), "Move Island puts keyboard focus on the status bar");
                ushort code = (ushort)KeyInterop.VirtualKeyFromKey(key);
                Send([new Input { Type = 1, Data = new() { Key = new() { Code = code } } },
                    new Input { Type = 1, Data = new() { Key = new() { Code = code, Flags = 2 } } }]);
                await Task.Delay(60);
            }
            async Task Press()
            {
                var bar = ((FrameworkElement)window.FindName("Strip")).IsVisible ? (FrameworkElement)window.FindName("Strip") : (FrameworkElement)window.FindName("Header");
                for (int i = 0; i < 2; i++)
                {
                    var at = bar.PointToScreen(new Point(bar.ActualWidth / 2, bar.ActualHeight / 2));
                    Move((int)Math.Round(at.X), (int)Math.Round(at.Y));
                    await window.WaitForPresentationAsync();
                }
                var cursor = System.Windows.Forms.Cursor.Position;
                Check(WindowFromPoint(cursor) == hwnd, "Only send button input into the owned synthetic island");
                SendMouse(2); pressed = true;
                await PresentationWait.UntilAsync(() => Mouse.Captured == bar, "The status bar must capture the native mouse press");
            }
            void Up() { SendMouse(4); pressed = false; }
            async Task Drag(int x, int y, IslandEdge edge)
            {
                int count = writes;
                await Press();
                var start = System.Windows.Forms.Cursor.Position;
                Move(x, y);
                await PresentationWait.UntilAsync(() => (System.Windows.Forms.Cursor.Position != start &&
                    !window.IsExpandedForAutomation && Mouse.Captured != null &&
                    (edge == IslandEdge.Free || Application.Current.Windows.OfType<IslandSnapPreview>().Any(value => value.IsVisible))),
                    "Moving the captured pointer shows the drag or snap preview");
                Check(writes == count, "The preview does not write settings");
                Up();
                await PresentationWait.UntilAsync(() => writes == count + 1 && session.Current.IslandPlacement?.Edge == edge,
                    "The native release saves exactly the expected placement: " + edge);
                await window.WaitForPresentationAsync();
                Check(!Application.Current.Windows.OfType<IslandSnapPreview>().Any(value => value.IsVisible),
                    "The preview is removed after dropping the island");
            }
        }
        finally
        {
            if (pressed) SendMouse(4);
            window.Close(); Move(original.X, original.Y);
        }
    }

    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void Move(int x, int y) { if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    private static void SendMouse(uint flags) => Send([new Input { Data = new() { Mouse = new() { Flags = flags } } }]);
    private static void Send(Input[] inputs)
    {
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    [StructLayout(LayoutKind.Sequential)] private struct Input { internal uint Type; internal Payload Data; }
    [StructLayout(LayoutKind.Explicit)] private struct Payload
    {
        [FieldOffset(0)] internal MouseInput Mouse;
        [FieldOffset(0)] internal KeyboardInput Key;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { internal int X, Y; internal uint Data, Flags, Time; internal UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { internal ushort Code, Scan; internal uint Flags, Time; internal UIntPtr Extra; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(System.Drawing.Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] input, int size);
}
