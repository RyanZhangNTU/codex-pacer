using System;
using System.Runtime.InteropServices;
using Windows.UI.ViewManagement;

namespace CodexPacer.Windows;

internal sealed class BackdropSystemSource : IBackdropSystemSource
{
    private readonly Action<Action> post;
    private UISettings? settings;
    private AccessibilitySettings? accessibility;
    private bool disposed;
    internal BackdropSystemSource(Action<Action> post)
    {
        this.post = post;
        try
        {
            settings = new UISettings(); accessibility = new AccessibilitySettings();
            settings.AdvancedEffectsEnabledChanged += EffectsChanged; accessibility.HighContrastChanged += ContrastChanged;
        }
        catch (Exception error) when (Recoverable(error)) { }
        Refresh();
    }
    public BackdropSystemState Current { get; private set; }
    public event Action? Changed;
    private void EffectsChanged(UISettings _, object value) => QueueRefresh();
    private void ContrastChanged(AccessibilitySettings _, object value) => QueueRefresh();
    private void QueueRefresh() => post(() => { if (!disposed) Refresh(); });
    internal void Refresh()
    {
        if (disposed) return;
        BackdropSystemState next;
        try { next = new(Environment.OSVersion.Version.Build, settings?.AdvancedEffectsEnabled == true, accessibility?.HighContrast == true,
            settings != null && accessibility != null); }
        catch (Exception error) when (Recoverable(error)) { next = new(Environment.OSVersion.Version.Build, false, false, false); }
        if (next == Current) return; Current = next; Changed?.Invoke();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        try { if (settings != null) settings.AdvancedEffectsEnabledChanged -= EffectsChanged; }
        catch (Exception error) when (Recoverable(error)) { }
        try { if (accessibility != null) accessibility.HighContrastChanged -= ContrastChanged; }
        catch (Exception error) when (Recoverable(error)) { }
        settings = null; accessibility = null;
    }
    private static bool Recoverable(Exception value) => value is COMException or TypeLoadException or NotSupportedException;
}
