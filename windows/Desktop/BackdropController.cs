using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace CodexPacer.Windows;

/// Owns one surface on the window dispatcher. System and device events do not
/// create a rendering timer or rewrite the user's saved appearance.
internal sealed class BackdropController : IDisposable
{
    private readonly IBackdropSystemSource system;
    private readonly Func<ICompositionBackdrop> create;
    private readonly Action<Action> post;
    private ICompositionBackdrop? native;
    private Action? removedHandler;
    private BackdropFrame? frame, applied;
    private string preferred = "classic";
    private bool failed, lost, disposed, glass;
    private long revision;
    internal event Action? Changed;
    internal BackdropDecision Decision { get; private set; }
    internal bool Glass => glass;
    internal IntPtr WindowHandle => native?.WindowHandle ?? IntPtr.Zero;
    internal void Hide() { if (disposed) return; if (frame != null) frame = frame with { Visible = false }; native?.Hide(); applied = null; }
    internal BackdropController(IBackdropSystemSource system, Func<ICompositionBackdrop> create, Action<Action> post)
    {
        this.system = system; this.create = create; this.post = post;
        Decision = BackdropPolicy.Resolve(preferred, system.Current); system.Changed += SystemChanged;
    }
    internal void Prefer(string value)
    {
        if (disposed || preferred == value) return;
        _ = BackdropPolicy.Resolve(value, system.Current);
        if (value == "liquidGlass") Drop();
        preferred = value; failed = lost = false; revision++; Refresh();
    }
    internal void Apply(BackdropFrame value, bool force = false)
    {
        if (disposed) return;
        frame = value;
        if (!value.Visible) { native?.Hide(); applied = null; return; }
        if (!Decision.Glass) return;
        if (!force && applied?.SameGeometry(value) == true) return;
        try
        {
            if (native == null)
            {
                var surface = create(); native = surface;
                removedHandler = () => Removed(surface); native.DeviceRemoved += removedHandler;
            }
            native.Apply(value); applied = value;
            if (!glass) { glass = true; Changed?.Invoke(); }
        }
        catch (Exception error) when (Recoverable(error)) { lost = error.HResult is unchecked((int)0x887A0005) or unchecked((int)0x887A0007); failed = !lost; Refresh(); }
    }
    private void SystemChanged() => post(() =>
    {
        if (disposed) return;
        if (lost || failed) Drop(); failed = lost = false; revision++; Refresh();
    });
    private void Removed(ICompositionBackdrop owner) => post(() =>
    { if (!disposed && ReferenceEquals(native, owner)) { lost = true; revision++; Refresh(); } });
    internal void GraphicsChanged() => post(() =>
    {
        if (disposed || !(lost || failed)) return;
        Drop(); failed = lost = false; revision++; Refresh();
    });
    private void Refresh()
    {
        var next = BackdropPolicy.Resolve(preferred, system.Current, failed, lost);
        bool changed = Decision != next;
        Decision = next;
        if (!next.Glass)
        {
            try { native?.MakeBlack(); } catch (Exception error) when (Recoverable(error)) { }
            changed |= glass; glass = false; applied = null;
            if (changed) Changed?.Invoke();
            long current = revision;
            // Let WPF submit its opaque surface before retiring the underlay.
            post(() => { if (!disposed && current == revision && !Decision.Glass) Drop(); });
        }
        else
        {
            if (changed) Changed?.Invoke();
            if (frame != null) Apply(frame, true);
        }
    }
    private void Drop()
    {
        if (native == null) return;
        var value = native; native = null; applied = null;
        value.DeviceRemoved -= removedHandler; removedHandler = null; value.Dispose();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true; revision++; glass = false;
        system.Changed -= SystemChanged; Drop(); system.Dispose();
    }
    private static bool Recoverable(Exception value) => value is COMException or Win32Exception or IOException or InvalidOperationException
        or DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or NotSupportedException;
}
