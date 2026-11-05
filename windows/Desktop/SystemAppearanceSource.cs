using System;
using System.ComponentModel;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed record SystemSemanticColors(Color Window, Color Text, Color Control, Color ControlText, Color Highlight, Color HighlightText, Color Disabled);
internal sealed record SystemAppearance(bool Dark, bool Animations, bool HighContrast, bool Transparency, int Build, bool Available, SystemSemanticColors Colors);
internal interface ISystemAppearanceSource : IDisposable
{
    SystemAppearance Current { get; }
    event Action? Changed;
}

/// One immutable snapshot, refreshed by system events on the owning dispatcher.
internal sealed class SystemAppearanceSource : ISystemAppearanceSource
{
    private readonly Action<Action> post;
    private readonly BackdropSystemSource effects;
    private int queued;
    private volatile bool disposed;
    public SystemAppearance Current { get; private set; }
    public event Action? Changed;
    internal SystemAppearanceSource(Action<Action> post)
    {
        this.post = post; effects = new(post); Current = Read();
        effects.Changed += Schedule;
        SystemParameters.StaticPropertyChanged += ParametersChanged;
        SystemEvents.UserPreferenceChanged += PreferencesChanged;
    }
    private void ParametersChanged(object? sender, PropertyChangedEventArgs args) => Schedule();
    private void PreferencesChanged(object sender, UserPreferenceChangedEventArgs args) => Schedule();
    internal void Refresh() { if (disposed) return; effects.Refresh(); Schedule(); }
    private void Schedule()
    {
        if (disposed || Interlocked.Exchange(ref queued, 1) != 0) return;
        post(() =>
        {
            Interlocked.Exchange(ref queued, 0); if (disposed) return;
            var next = Read(); if (next == Current) return; Current = next; Changed?.Invoke();
        });
    }
    private SystemAppearance Read()
    {
        var value = effects.Current;
        return new(SettingsWindow.IsSystemDark(), SystemParameters.ClientAreaAnimation, SystemParameters.HighContrast || value.HighContrast,
            value.Transparency, value.Build, value.Available,
            new(SystemColors.WindowColor, SystemColors.WindowTextColor, SystemColors.ControlColor, SystemColors.ControlTextColor,
                SystemColors.HighlightColor, SystemColors.HighlightTextColor, SystemColors.GrayTextColor));
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        effects.Changed -= Schedule; effects.Dispose();
        SystemParameters.StaticPropertyChanged -= ParametersChanged; SystemEvents.UserPreferenceChanged -= PreferencesChanged;
    }
}

/// BackdropController owns this subscription; the window owns the shared source.
internal sealed class AppearanceBackdropSource : IBackdropSystemSource
{
    private readonly ISystemAppearanceSource source;
    public BackdropSystemState Current => new(source.Current.Build, source.Current.Transparency, source.Current.HighContrast, source.Current.Available);
    public event Action? Changed;
    internal AppearanceBackdropSource(ISystemAppearanceSource source) { this.source = source; source.Changed += Refresh; }
    private void Refresh() => Changed?.Invoke();
    public void Dispose() => source.Changed -= Refresh;
}

internal static class DesktopAppearance
{
    public static readonly DependencyProperty HighContrastProperty = DependencyProperty.RegisterAttached("HighContrast", typeof(bool), typeof(DesktopAppearance), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.Inherits));
    public static bool GetHighContrast(DependencyObject value) => (bool)value.GetValue(HighContrastProperty);
    public static void SetHighContrast(DependencyObject value, bool enabled) => value.SetValue(HighContrastProperty, enabled);
    internal static void Apply(DependencyObject value, SystemAppearance snapshot) => SetHighContrast(value, snapshot.HighContrast);
    internal static SolidColorBrush Ink(Color value) { var brush = new SolidColorBrush(value); brush.Freeze(); return brush; }
}
