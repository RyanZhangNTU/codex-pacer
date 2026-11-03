using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// Overrides current paint values without removing their binding or resource source.
internal sealed class HighContrastScope(FrameworkElement root) : IDisposable
{
    private readonly Dictionary<DependencyObject, List<Paint>> entries = [];
    private readonly Dictionary<DependencyObject, List<(DependencyPropertyDescriptor Descriptor, EventHandler Handler)>> states = [];
    private bool applying, active, disposed;
    private Brush text = Brushes.White, controlText = Brushes.White, control = Brushes.Black, highlight = Brushes.White, highlightText = Brushes.Black, disabled = Brushes.Gray;
    private sealed class Paint(DependencyObject owner, DependencyProperty property, Action change)
    {
        internal readonly DependencyObject Owner = owner;
        internal readonly DependencyProperty Property = property;
        internal object? Original = owner.GetValue(property), Applied;
        internal readonly DependencyPropertyDescriptor Descriptor = DependencyPropertyDescriptor.FromProperty(property, owner.GetType());
        internal readonly EventHandler Handler = (_, _) => change();
    }
    internal void Apply(SystemAppearance next)
    {
        if (!next.HighContrast) { Stop(); return; }
        var colors = next.Colors;
        text = DesktopAppearance.Ink(colors.Text); controlText = DesktopAppearance.Ink(colors.ControlText); control = DesktopAppearance.Ink(colors.Control);
        highlight = DesktopAppearance.Ink(colors.Highlight); highlightText = DesktopAppearance.Ink(colors.HighlightText); disabled = DesktopAppearance.Ink(colors.Disabled);
        if (!active) { active = true; root.LayoutUpdated += Layout; }
        Discover(); foreach (var entry in entries.Values) foreach (var paint in entry) Update(paint);
    }
    private void Layout(object? sender, EventArgs args) => Discover();
    private void Discover()
    {
        if (disposed || !active || applying) return;
        var present = new HashSet<DependencyObject>();
        Visit(root);
        foreach (var key in entries.Keys.Where(key => !present.Contains(key)).ToArray()) Remove(key);
        void Visit(DependencyObject value)
        {
            present.Add(value);
            if (!entries.ContainsKey(value))
            {
                var properties = new List<DependencyProperty>();
                if (value is TextBlock) properties.Add(TextBlock.ForegroundProperty);
                if (value is TextElement) properties.Add(TextElement.ForegroundProperty);
                if (value is IconGlyph) properties.Add(IconGlyph.InkProperty);
                if (value is Control) { properties.Add(Control.ForegroundProperty); properties.Add(Control.BackgroundProperty); }
                if (value is Border) properties.Add(Border.BorderBrushProperty);
                if (properties.Count > 0)
                {
                    var list = new List<Paint>(); entries[value] = list;
                    foreach (var property in properties)
                    {
                        Paint? paint = null; paint = new(value, property, () => Update(paint!)); list.Add(paint);
                        paint.Descriptor.AddValueChanged(value, paint.Handler); Update(paint);
                    }
                    var observed = new List<(DependencyPropertyDescriptor, EventHandler)>(); states[value] = observed;
                    if (value is UIElement) Observe(UIElement.IsEnabledProperty);
                    if (value is ToggleButton) Observe(ToggleButton.IsCheckedProperty);
                    if (value is ListBoxItem) Observe(ListBoxItem.IsSelectedProperty);
                    if (value is MenuItem) Observe(MenuItem.IsHighlightedProperty);
                    void Observe(DependencyProperty property)
                    {
                        var descriptor = DependencyPropertyDescriptor.FromProperty(property, value.GetType());
                        EventHandler handler = (_, _) => { foreach (var paint in list) Update(paint); };
                        descriptor.AddValueChanged(value, handler); observed.Add((descriptor, handler));
                    }
                }
            }
            if (value is TextBlock block) foreach (var inline in block.Inlines) Visit(inline);
            if (value is Span span) foreach (var inline in span.Inlines) Visit(inline);
            if (value is Visual) for (int index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) Visit(VisualTreeHelper.GetChild(value, index));
        }
    }
    private void Update(Paint paint)
    {
        if (applying || !active || disposed) return;
        object value = paint.Owner.GetValue(paint.Property);
        if (!ReferenceEquals(value, paint.Applied)) paint.Original = value;
        bool selected = Selected(paint.Owner);
        Brush next = paint.Property == Control.BackgroundProperty ? selected ? highlight : control
            : paint.Property == Border.BorderBrushProperty ? value is SolidColorBrush { Color.A: 0 } ? (Brush)value : highlight
            : paint.Owner is UIElement { IsEnabled: false } ? disabled : selected ? highlightText : paint.Owner is Control ? controlText : text;
        applying = true;
        try { paint.Applied = next; paint.Owner.SetCurrentValue(paint.Property, next); }
        finally { applying = false; }
    }
    private static bool Selected(DependencyObject value)
    {
        DependencyObject? cursor = value;
        while (cursor != null)
        {
            if (cursor is RadioButton { IsChecked: true } radio && System.Windows.Automation.AutomationProperties.GetAutomationId(radio).StartsWith("settings.pane.", StringComparison.Ordinal)) return true;
            if (cursor is ListBoxItem { IsSelected: true } or MenuItem { IsHighlighted: true }) return true;
            cursor = cursor is Visual ? VisualTreeHelper.GetParent(cursor) : (cursor as FrameworkContentElement)?.Parent;
        }
        return false;
    }
    private void Remove(DependencyObject key)
    {
        applying = true;
        try
        {
            foreach (var item in states[key]) item.Descriptor.RemoveValueChanged(key, item.Handler); states.Remove(key);
            foreach (var paint in entries[key])
            {
                paint.Descriptor.RemoveValueChanged(key, paint.Handler); key.SetCurrentValue(paint.Property, paint.Original);
                BindingOperations.GetBindingExpression(key, paint.Property)?.UpdateTarget();
            }
            entries.Remove(key);
        }
        finally { applying = false; }
    }
    private void Stop()
    {
        if (!active) return; active = false; root.LayoutUpdated -= Layout;
        foreach (var key in entries.Keys.ToArray()) Remove(key);
    }
    public void Dispose() { if (disposed) return; Stop(); disposed = true; }
}
