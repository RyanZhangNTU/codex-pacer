using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class AccessibilityChecks
{
    internal static async Task Run(string language)
    {
        Check(IslandWindow.IsPagingInput(Key.System, Key.Left, ModifierKeys.None, false)
            && IslandWindow.IsPagingInput(Key.System, Key.Right, ModifierKeys.Alt, false)
            && IslandWindow.IsPagingInput(Key.Right, Key.None, ModifierKeys.Alt, false), "Paging accepts WPF SystemKey and explicit Alt arrows");
        Check(!IslandWindow.IsPagingInput(Key.Left, Key.None, ModifierKeys.None, false)
            && !IslandWindow.IsPagingInput(Key.System, Key.Left, ModifierKeys.Alt, true)
            && !IslandWindow.IsPagingInput(Key.System, Key.F4, ModifierKeys.Alt, false), "Editing, ordinary arrows and other system shortcuts retain their own behavior");
        using var appearance = new AppearanceFixture();
        await using var engine = new EngineClient();
        var surfaces = new List<CompositionFixture>();
        var window = new IslandWindow(engine, true, language == "zh-Hans", appearanceSource: appearance,
            backdropFactory: _ => { var value = new CompositionFixture(); surfaces.Add(value); return value; },
            openConversation: (_, _) => Task.FromResult(true)) { IsHitTestVisible = false };
        var ui = UiText.For(language == "zh-Hans");
        try
        {
            window.ApplyPreferences(new() { IslandAppearance = "liquidGlass" }); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.Presentation?.Rows.Count >= 7, "The offline fixture supplies three task pages");
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            Check(!window.IsActive && !window.ShowInTaskbar, "Appearance subscriptions do not activate the island or add a taskbar entry");
            var main = (Button)window.FindName("HeaderAction");
            var peer = new ButtonAutomationPeer(main);
            Check(peer.GetAutomationControlType() == AutomationControlType.Button && peer.GetName() == ui.Text("common.pin") && main.Focusable,
                "The collapsed row exposes a named, focusable primary button");
            await Audit(window);
            CheckHoverTooltips(window, "collapsed");
            Invoke(main); await PresentationWait.UntilAsync(() => window.IsExpandedForAutomation, "UIA invokes the collapsed primary action");
            Check(peer.GetName() == ui.Text("common.unpin"), "The primary action updates its accessible pin state");
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            // Activate only this QA window for keyboard assertions. Product startup remains non-activating.
            window.Activate(); Check(main.Focus(), "An explicitly focused island accepts keyboard input");
            PostKey(window, Key.Space); await PresentationWait.UntilAsync(() => window.IsExpandedForAutomation, "Space invokes the focused primary action");
            await window.WaitForPresentationAsync();
            Check(main.MoveFocus(new TraversalRequest(FocusNavigationDirection.Next)) && Keyboard.FocusedElement is UIElement { IsVisible: true, Focusable: true } next && next != main,
                "Tab advances from the primary action to a visible control");
            CheckFocusOrder(window, main); main.Focus();
            bool systemKeyObserved = false;
            window.AddHandler(Keyboard.KeyDownEvent, new KeyEventHandler((_, args) => { if (args.Key == Key.System && args.SystemKey == Key.Right) systemKeyObserved = true; }), true);
            var pages = (Grid)window.FindName("TaskPages");
            var oldPage = pages.Children.OfType<RevealHost>().Last();
            var oldRow = Descendants(oldPage).OfType<TaskRow>().First();
            PostKey(window, Key.Right, true);
            await PresentationWait.UntilAsync(() => ((TextBlock)window.FindName("PageNumber")).Text == "2 / 3", "Alt+Right pages through the actual HWND input path");
            Check(systemKeyObserved, "WM_SYSKEYDOWN reaches the WPF SystemKey branch");
            Check(!oldPage.IsEnabled && !oldPage.IsHitTestVisible && !oldPage.IsAccessible && !oldRow.IsEnabled,
                "The exiting page becomes non-interactive before removal");
            Check(UIElementAutomationPeer.CreatePeerForElement(oldPage).GetChildren()?.Count is null or 0,
                "The exiting page immediately leaves the accessible tree");
            RejectDisabled(oldRow);
            var hovered = Descendants(pages.Children.OfType<RevealHost>().Last()).OfType<TaskRow>().First();
            hovered.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseEnterEvent });
            Check(hovered.HasAnimatedProperties, "The current row has a finite hover transition to interrupt");
            appearance.Set(appearance.Current with { Animations = false }); await Drain();
            Check(window.AccessibilityMotionState is (1, 0), "Disabling animation mid-page removes outgoing content and all finite clocks");
            Check(((RevealHost)pages.Children[0]).Opacity == 1 && !((RevealHost)pages.Children[0]).HasAnimatedProperties,
                "The incoming page immediately reaches its final opacity without a retained clock");
            Check(!hovered.HasAnimatedProperties && hovered.HoverProgress == 1, "Reduced motion immediately settles the active hover and releases its clock");
            var quota = (AlternatingQuotaText)window.FindName("QuotaLabel");
            var badge = (ActivityBadge)window.FindName("Badge");
            Check(!quota.Scheduling.Scheduled && quota.Scheduling.Clocks == 0 && !badge.RotationScheduling.Composed && !badge.RotationScheduling.FallbackClock
                && !badge.TransientMotion.Ripple && !badge.TransientMotion.Bloom, "Reduced motion removes quota deadlines, orbit and transient clocks");
            PostKey(window, Key.Left, true); await PresentationWait.UntilAsync(() => ((TextBlock)window.FindName("PageNumber")).Text == "1 / 3", "Alt+Left reverses the page");
            PostKey(window, Key.Left, true); await Drain();
            Check(((TextBlock)window.FindName("PageNumber")).Text == "1 / 3" && window.AccessibilityMotionState.PageClocks == 0,
                "Repeated boundary input neither changes the page nor starts a clock in reduced motion");
            appearance.Set(appearance.Current with { Animations = true }); await Drain();
            bool interrupted = false;
            void Interrupt(MotionFrame frame)
            { if (!frame.Finished && !interrupted) { interrupted = true; appearance.Set(appearance.Current with { Animations = false }); } }
            window.FrameApplied += Interrupt; window.CollapseForAutomation(); window.Reveal(); window.CollapseForAutomation();
            await PresentationWait.UntilAsync(() => interrupted, "The window transition presents an intermediate frame");
            await window.WaitForPresentationAsync(); window.FrameApplied -= Interrupt;
            Check(!window.IsExpandedForAutomation && window.LogicalTarget.Height == 36 && window.AccessibilityMotionState is (1, 0),
                "Mid-animation reduction settles the latest reversed window target");
            appearance.Set(appearance.Current with { Transparency = false }); await Drain();
            Check(!window.GlassVisible, "The shared appearance snapshot immediately disables transparent material");
            appearance.Set(appearance.Current with { Transparency = true }); await Drain();
            Check(window.GlassVisible, "Restoring system transparency restores the user's Glass preference");
            window.Reveal(); await window.WaitForPresentationAsync();
            CheckHoverTooltips(window, "expanded");
            appearance.Set(appearance.Current with { HighContrast = true }); await Drain(); window.UpdateLayout();
            Check(!window.GlassVisible && ((SolidColorBrush)((Border)window.FindName("Shell")).Background).Color == appearance.Current.Colors.Window,
                "High contrast selects the semantic window background and disables Glass");
            Check(window.Background is SolidColorBrush { Color.A: 0 }, "High contrast preserves the island's transparent outer HWND area");
            var title = Descendants(window).OfType<TextBlock>().First(value => System.Windows.Data.BindingOperations.IsDataBound(value, TextBlock.ForegroundProperty));
            var binding = System.Windows.Data.BindingOperations.GetBindingExpression(title, TextBlock.ForegroundProperty);
            Check(((SolidColorBrush)title.Foreground).Color == appearance.Current.Colors.Text, "Bound task text uses the injected high-contrast text color");
            appearance.Set(appearance.Current with { HighContrast = false, Dark = true }); await Drain();
            Check(window.GlassVisible && ReferenceEquals(binding, System.Windows.Data.BindingOperations.GetBindingExpression(title, TextBlock.ForegroundProperty)),
                "Leaving high contrast restores material and preserves the original text binding");
            appearance.Set(appearance.Current with { Animations = true }); await Drain();
            Invoke((Button)window.FindName("NextPage"));
            await PresentationWait.UntilAsync(() => ((TextBlock)window.FindName("PageNumber")).Text == "2 / 3", "The hide fixture starts a normal page transition");
            var menu = ((Button)window.FindName("MoreButton")).ContextMenu;
            menu.IsOpen = true; await Drain();
            var hiddenHover = Descendants(pages.Children.OfType<RevealHost>().Last()).OfType<TaskRow>().First();
            hiddenHover.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseEnterEvent });
            Check(hiddenHover.HasAnimatedProperties, "The hide fixture starts an active hover");
            window.Hide(); await Drain();
            Check(new IslandWindowAutomationPeer(window).GetChildren()?.Count is null or 0, "Hidden islands have no accessible children");
            Check(!main.IsEnabled && window.AccessibilityMotionState.PageClocks == 0 && !quota.Scheduling.Scheduled,
                "Hidden islands disable actions and remove animation work");
            Check(!menu.IsOpen && !menu.IsEnabled, "Hiding also closes and disables the separate context-menu surface");
            Check(!hiddenHover.HasAnimatedProperties && hiddenHover.HoverProgress == 0, "Hiding immediately releases hover clocks on the retained page");
            window.Show(); await window.WaitForPresentationAsync(); Check(main.IsEnabled, "Showing the island restores its primary action");
            await Audit(window);
            await AccessibilitySettingsChecks.Run(language, appearance, engine, window);
            await AccessibilityGuideChecks.Run(language, appearance, engine);
        }
        finally { window.AllowClose = true; window.Close(); }
        Check(appearance.Subscribers == 0 && !appearance.Disposed && surfaces.All(value => value.Disposed), "Closing releases borrowed subscriptions and every material without disposing the shared source");
        Console.WriteLine("PASS accessibility " + language + ": actual UIA, keyboard, retired pages, live appearance, motion shutdown and cleanup");
    }
    internal static Task Audit(Window window, string context = "island") => AuditHandle(new WindowInteropHelper(window).Handle, context);
    internal static async Task AuditHandle(IntPtr hwnd, string context)
    {
        var entries = await Task.Run(() =>
        {
            var root = AutomationElement.FromHandle(hwnd);
            return root.FindAll(TreeScope.Descendants, Automation.ControlViewCondition).Cast<AutomationElement>()
                .Select(value => (value.Current.ControlType, value.Current.ClassName, value.Current.AutomationId, value.Current.Name, value.Current.IsEnabled, value.Current.IsOffscreen, value.Current.IsKeyboardFocusable,
                    Invoke: value.TryGetCurrentPattern(InvokePattern.Pattern, out _), Toggle: value.TryGetCurrentPattern(TogglePattern.Pattern, out _),
                    Select: value.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _))).ToArray();
        }).WaitAsync(TimeSpan.FromSeconds(15));
        int actions = 0;
        foreach (var entry in entries.Where(value => value.IsEnabled && !value.IsOffscreen))
        {
            bool action = entry.ControlType == ControlType.Button || entry.ControlType == ControlType.CheckBox || entry.ControlType == ControlType.RadioButton
                || entry.ControlType == ControlType.ComboBox || entry.ControlType == ControlType.Edit || entry.ControlType == ControlType.Thumb || entry.ControlType == ControlType.ScrollBar || entry.ControlType == ControlType.ListItem || entry.IsKeyboardFocusable;
            if (!action) continue; actions++;
            Check(!string.IsNullOrWhiteSpace(entry.Name), context + ": UIA requires a name for " + entry.ControlType.ProgrammaticName + " " + entry.ClassName + " " + entry.AutomationId);
            if (entry.ControlType == ControlType.Button) Check(entry.Invoke || entry.Toggle, "UIA buttons expose Invoke or Toggle: " + entry.AutomationId);
            if (entry.ControlType == ControlType.CheckBox) Check(entry.Toggle, "UIA checkboxes expose Toggle: " + entry.AutomationId);
            if (entry.ControlType == ControlType.RadioButton) Check(entry.Select, context + ": UIA radio choices expose SelectionItem: " + entry.ClassName + " " + entry.AutomationId);
        }
        Check(actions > 0, "The actual HWND must expose interactive UIA controls");
    }
    internal static void RejectDisabled(Button button)
    {
        bool rejected = false;
        try { ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)!).Invoke(); }
        catch (ElementNotEnabledException) { rejected = true; }
        Check(rejected, "A retained peer cannot invoke an exiting page");
    }
    internal static void CheckFocusOrder(Window window, UIElement first)
    {
        Check(first.Focus(), "The first keyboard action can receive focus");
        var visited = new HashSet<IInputElement> { first };
        UIElement current = first;
        for (int step = 0; step < 32; step++)
        {
            if (!current.MoveFocus(new TraversalRequest(FocusNavigationDirection.Next))) break;
            Check(Keyboard.FocusedElement is UIElement { IsVisible: true, IsEnabled: true, Focusable: true } item && Window.GetWindow(item) == window,
                "Tab order stays within the current visible, enabled window content");
            current = (UIElement)Keyboard.FocusedElement;
            if (!visited.Add(current)) break;
            var peer = UIElementAutomationPeer.CreatePeerForElement(current);
            Check(peer != null && !string.IsNullOrWhiteSpace(peer.GetName()), "Each keyboard stop exposes an accessible name");
        }
        Check(visited.Count >= 3, "The keyboard order includes the main action and neighboring controls");
        first.Focus(); Check(first.MoveFocus(new TraversalRequest(FocusNavigationDirection.Next)), "The next keyboard action remains reachable");
        Check(((UIElement)Keyboard.FocusedElement).MoveFocus(new TraversalRequest(FocusNavigationDirection.Previous)) && Keyboard.FocusedElement == first,
            "Reverse focus traversal returns to the preceding primary action");
    }
    internal static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)!).Invoke();
    internal static async Task Drain() { await Dispatcher.Yield(DispatcherPriority.ContextIdle); await Task.Delay(25); await Dispatcher.Yield(DispatcherPriority.ContextIdle); }
    internal static void PostKey(Window window, Key key, bool system = false)
    {
        int virtualKey = KeyInterop.VirtualKeyFromKey(key);
        long flags = 1L | ((long)MapVirtualKey((uint)virtualKey, 0) << 16) | (system ? 1L << 29 : 0);
        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        Check(PostMessage(hwnd, system ? 0x0104u : 0x0100u, new(virtualKey), new(flags))
            && PostMessage(hwnd, system ? 0x0105u : 0x0101u, new(virtualKey), new(flags | (1L << 30) | (1L << 31))), "The test key is posted only to its owned HWND");
    }
    internal static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    /// Only the expanded island's first toolbar row shows hover tooltips; the
    /// rest of the island keeps its descriptions for assistive technology.
    private static void CheckHoverTooltips(IslandWindow window, string state)
    {
        var toolbar = (FrameworkElement)window.FindName("TaskToolbar");
        var stray = SelfAndDescendants(window).OfType<FrameworkElement>()
            .Where(element => element.ToolTip != null && element != toolbar && !toolbar.IsAncestorOf(element))
            .Select(element => element.GetType().Name + ":" + AutomationProperties.GetAutomationId(element)).ToArray();
        Check(stray.Length == 0, "Only the first toolbar row shows hover tooltips (" + state + "): " + string.Join(", ", stray));
        Check(new[] { "PreviousPage", "NextPage", "MarkReadButton", "PinButton", "SettingsButton", "MoreButton" }
            .All(name => ((Button)window.FindName(name)).ToolTip is string { Length: > 0 }), "The first toolbar row keeps its button tooltips (" + state + ")");
        var row = SelfAndDescendants(window).OfType<TaskRow>().FirstOrDefault();
        Check(row == null || AutomationProperties.GetHelpText(row).Length > 0, "Task rows keep their open help for screen readers (" + state + ")");
    }
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint = "MapVirtualKeyW")] private static extern uint MapVirtualKey(uint code, uint type);
}

internal sealed class AppearanceFixture : ISystemAppearanceSource
{
    public SystemAppearance Current { get; private set; } = new(false, true, false, true, 26200, true,
        new(Colors.Black, Colors.White, Colors.Black, Colors.White, Colors.Yellow, Colors.Black, Colors.Silver));
    private Action? changed;
    internal int Subscribers => changed?.GetInvocationList().Length ?? 0;
    internal bool Disposed;
    public event Action? Changed { add => changed += value; remove => changed -= value; }
    internal void Set(SystemAppearance next) { Current = next; changed?.Invoke(); }
    public void Dispose() => Disposed = true;
}

internal sealed class CompositionFixture : ICompositionBackdrop
{
    public IntPtr WindowHandle => IntPtr.Zero;
    public event Action? DeviceRemoved { add { } remove { } }
    internal bool Disposed;
    public void Apply(BackdropFrame frame) { }
    public void MakeBlack() { }
    public void Hide() { }
    public void Dispose() => Disposed = true;
}
