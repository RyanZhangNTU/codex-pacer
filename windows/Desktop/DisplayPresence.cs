using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// Whether anyone can see this session's desktop: it is unlocked, attached
/// to a console or remote display, and that display is powered on. Cosmetic
/// motion stops while it is false. Nothing polls: session changes arrive
/// through SystemEvents, display power through a power-setting notification
/// on a message-only window. Create it on a dispatcher thread; `Changed`
/// is raised there.
internal sealed class DisplayPresence : IDisposable
{
    private const int PowerBroadcast = 0x0218, PowerSettingChange = 0x8013;
    // GUID_SESSION_DISPLAY_STATUS follows this session's display, unlike the
    // console's state, so a remote session is not stopped by a dark console.
    private static readonly Guid SessionDisplay = new("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");
    private readonly Dispatcher dispatcher;
    private readonly HwndSource? source;
    private readonly IntPtr registration;
    private bool disposed;
    internal bool Locked { get; private set; }
    internal bool Disconnected { get; private set; }
    internal bool DisplayOff { get; private set; }
    internal bool Present => !Locked && !Disconnected && !DisplayOff;
    internal event Action? Changed;

    internal DisplayPresence() : this(observe: true) { }
    /// <param name="observe">False builds a presence that only changes through
    /// `Apply`, for checks that must not depend on the real session.</param>
    internal DisplayPresence(bool observe)
    {
        dispatcher = Dispatcher.CurrentDispatcher;
        if (!observe) return;
        SystemEvents.SessionSwitch += SessionSwitched;
        try
        {
            source = new HwndSource(new HwndSourceParameters("Codex Pacer display presence") { ParentWindow = new IntPtr(-3), WindowStyle = 0 });
            source.AddHook(Message);
            var setting = SessionDisplay;
            registration = RegisterPowerSettingNotification(source.Handle, ref setting, 0);
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or ExternalException)
        {
            // Without the window the session events still apply; the display counts as on.
            source?.Dispose(); source = null;
        }
    }

    /// Applies a session change, as SystemEvents reports it.
    internal void Apply(SessionSwitchReason reason)
    {
        switch (reason)
        {
            case SessionSwitchReason.SessionLock: Set(locked: true); break;
            case SessionSwitchReason.SessionUnlock: Set(locked: false); break;
            case SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect: Set(disconnected: true); break;
            case SessionSwitchReason.ConsoleConnect or SessionSwitchReason.RemoteConnect: Set(disconnected: false); break;
        }
    }
    /// Applies the session display's power state: 0 off, 1 on, 2 dimmed (still visible).
    internal void ApplyDisplayState(uint value) => Set(displayOff: value == 0);

    private void SessionSwitched(object? sender, SessionSwitchEventArgs args)
    {
        if (dispatcher.CheckAccess()) Apply(args.Reason);
        else dispatcher.BeginInvoke(() => Apply(args.Reason));
    }
    private IntPtr Message(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message != PowerBroadcast || wparam.ToInt64() != PowerSettingChange || lparam == IntPtr.Zero) return IntPtr.Zero;
        var setting = Marshal.PtrToStructure<PowerSetting>(lparam);
        if (setting.Setting == SessionDisplay && setting.Length >= sizeof(uint)) ApplyDisplayState(setting.Data);
        return IntPtr.Zero;
    }
    private void Set(bool? locked = null, bool? disconnected = null, bool? displayOff = null)
    {
        if (disposed) return;
        bool before = Present;
        Locked = locked ?? Locked; Disconnected = disconnected ?? Disconnected; DisplayOff = displayOff ?? DisplayOff;
        if (Present != before) Changed?.Invoke();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        SystemEvents.SessionSwitch -= SessionSwitched;
        if (registration != IntPtr.Zero) UnregisterPowerSettingNotification(registration);
        if (source != null) { source.RemoveHook(Message); source.Dispose(); }
        Changed = null;
    }

    [StructLayout(LayoutKind.Sequential)] private struct PowerSetting { internal Guid Setting; internal uint Length; internal uint Data; }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, int flags);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
}
