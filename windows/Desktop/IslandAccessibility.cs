using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private ISystemAppearanceSource appearance = null!;
    private bool ownsAppearance;
    private HighContrastScope semanticPaint = null!;
    internal ISystemAppearanceSource AppearanceSource => appearance;
    private void InitializeAppearance(ISystemAppearanceSource? source)
    {
        appearance = source ?? new SystemAppearanceSource(action => Dispatcher.BeginInvoke(action)); ownsAppearance = source == null;
        semanticPaint = new(this); DesktopAppearance.Apply(this, appearance.Current);
        appearance.Changed += AppearanceChanged;
        Loaded += (_, _) => ApplyAppearance();
        UpdateMainAction();
    }
    private void AppearanceChanged() => Dispatcher.InvokeAsync(() => { if (!presentationStopped) ApplyAppearance(); });
    private void ApplyAppearance()
    {
        var state = appearance.Current; DesktopAppearance.Apply(this, state);
        if (!AnimationsEnabled) FinishPageTransition();
        UpdateCompactBar();
        RefreshRowMotion();
        if (rendering) OnRenderFrame(this, EventArgs.Empty);
        RefreshSurface(); semanticPaint.Apply(state);
    }
    private void RefreshRowMotion()
    { foreach (var row in TaskRowsIn(TaskPages)) { row.SetAnimations(DecorationsAnimate); row.ApplyAppearance(); } }
    private void DisposeAppearance()
    {
        appearance.Changed -= AppearanceChanged; semanticPaint.Dispose(); if (ownsAppearance) appearance.Dispose();
    }
    private void OnMainAction(object sender, RoutedEventArgs args) { if (IsVisible && !presentationStopped) { SetPinned(!pinned); SetExpanded(true); } }
    private void UpdateMainAction()
    {
        string name = ui.Text(pinned ? "common.unpin" : "common.pin");
        foreach (var button in new[] { HeaderAction, StripAction }) { SetButtonName(button, name, tooltip: false); AutomationProperties.SetAutomationId(button, button == HeaderAction ? "island.main.row" : "island.main.strip"); }
    }
    private void FinishPageTransition()
    {
        foreach (var clock in pageClocks) clock.Dispose(); pageClocks.Clear();
        if (currentPage == null) return;
        TaskPages.Children.Clear(); currentPage.ApplyAnimationClock(OpacityProperty, null); currentPage.Opacity = 1;
        if (currentPage.RenderTransform is TranslateTransform transform) { transform.ApplyAnimationClock(TranslateTransform.XProperty, null); transform.X = 0; }
        TaskPages.Children.Add(currentPage);
    }
    internal (int Pages, int PageClocks, int DimClocks) AccessibilityMotionState => (TaskPages.Children.Count, pageClocks.Count(clock => clock.IsActive), dimClocks.Values.Count(clock => clock.IsActive));
    internal static bool IsPagingInput(Key key, Key systemKey, ModifierKeys modifiers, bool editing)
        => !editing && (key == Key.System || (modifiers & ModifierKeys.Alt) != 0) && (key == Key.System ? systemKey : key) is Key.Left or Key.Right;
    private static bool IsEditing(DependencyObject? value)
    {
        while (value != null)
        {
            if (value is TextBoxBase or PasswordBox or ComboBox) return true;
            value = value is Visual ? VisualTreeHelper.GetParent(value) : (value as FrameworkContentElement)?.Parent;
        }
        return false;
    }
}
