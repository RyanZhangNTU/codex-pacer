using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using CodexPacer.Windows;

internal static class SystemAppearanceUnitChecks
{
    internal static void Run()
    {
        Check(IslandWindow.IsPagingInput(Key.System, Key.Left, ModifierKeys.None, false)
            && IslandWindow.IsPagingInput(Key.Right, Key.None, ModifierKeys.Alt, false), "Both system-key and explicit-Alt routes page");
        Check(!IslandWindow.IsPagingInput(Key.Left, Key.None, ModifierKeys.None, false)
            && !IslandWindow.IsPagingInput(Key.System, Key.Right, ModifierKeys.Alt, true), "Ordinary arrows and editing retain their own input");
        using var source = new AppearanceFixture();
        int changes = 0;
        var adapter = new AppearanceBackdropSource(source); adapter.Changed += () => changes++;
        source.Set(source.Current with { Transparency = false });
        Check(changes == 1 && !adapter.Current.Transparency && source.Subscribers == 1, "Backdrop state uses the same immutable system snapshot");
        source.Set(source.Current with { HighContrast = true });
        Check(changes == 2 && adapter.Current.HighContrast, "High contrast reaches the material policy");
        adapter.Dispose(); source.Set(source.Current with { HighContrast = false, Transparency = true });
        Check(changes == 2 && source.Subscribers == 0 && !source.Disposed, "Disposing a borrower detaches callbacks without disposing its source");

        var ink = new InkSource(); var text = new TextBlock { Text = "QA" };
        text.SetBinding(TextBlock.ForegroundProperty, new Binding(nameof(InkSource.Value)) { Source = ink });
        var binding = BindingOperations.GetBindingExpression(text, TextBlock.ForegroundProperty);
        var root = new Border { Background = Brushes.Transparent, Child = text };
        root.Measure(new(100, 30)); root.Arrange(new(0, 0, 100, 30));
        using var paint = new HighContrastScope(root);
        paint.Apply(source.Current with { HighContrast = true });
        Check(((SolidColorBrush)text.Foreground).Color == source.Current.Colors.Text && root.Background is SolidColorBrush { Color.A: 0 },
            "Semantic paint changes text and preserves transparent geometry");
        ink.Set(Brushes.Green); binding!.UpdateTarget();
        Check(((SolidColorBrush)text.Foreground).Color == source.Current.Colors.Text, "Live bindings stay semantic while high contrast is active");
        paint.Apply(source.Current with { HighContrast = false });
        Check(ReferenceEquals(binding, BindingOperations.GetBindingExpression(text, TextBlock.ForegroundProperty)) && ReferenceEquals(text.Foreground, Brushes.Green),
            "Leaving high contrast restores the latest binding value");
        paint.Dispose(); ink.Set(Brushes.Red); binding.UpdateTarget();
        Check(ReferenceEquals(text.Foreground, Brushes.Red), "A disposed scope cannot repaint later binding updates");
        var page = new Border { Child = new Button() }; PageAccessibility.Retire(page);
        Check(!page.IsEnabled && !page.IsHitTestVisible && KeyboardNavigation.GetTabNavigation(page) == KeyboardNavigationMode.None,
            "Retired content cannot accept pointer or keyboard actions");
        var value = new Border { Opacity = 1 };
        var lease = new AnimationLease(new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)), clock => value.ApplyAnimationClock(UIElement.OpacityProperty, clock));
        Check(lease.IsActive && value.HasAnimatedProperties, "The finite lease owns its property clock");
        lease.Dispose(); lease.Dispose();
        Check(!lease.IsActive && !value.HasAnimatedProperties && value.Opacity == 1, "Cancellation is immediate, idempotent and leaves no property clock");
        Console.WriteLine("PASS headless appearance units: system-key routing, snapshot ownership, semantic bindings, retirement and finite clocks");
    }
    private sealed class InkSource : INotifyPropertyChanged
    {
        public Brush Value { get; private set; } = Brushes.Blue;
        public event PropertyChangedEventHandler? PropertyChanged;
        internal void Set(Brush value) { Value = value; PropertyChanged?.Invoke(this, new(nameof(Value))); }
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
