using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed class WindowsDisplayTopology : IDisplayTopologySource
{
    private readonly Action<Action> post;
    private bool disposed, queued;
    public IReadOnlyList<DisplayMonitor> Current { get; private set; } = Array.Empty<DisplayMonitor>();
    public event Action? Changed;
    internal WindowsDisplayTopology(Action<Action> post)
    {
        this.post = post; Refresh();
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
    }
    private void DisplayChanged(object? sender, EventArgs args) => post(() => Refresh());
    public void Refresh()
    {
        if (disposed || queued) return;
        queued = true;
        try
        {
            var found = new List<DisplayMonitor>();
            bool Read(IntPtr monitor, IntPtr dc, ref ScreenRectangle rectangle, IntPtr data)
            {
                var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>(), Device = "" };
                if (!GetMonitorInfo(monitor, ref info) || !info.Bounds.Valid || !info.Work.Valid) return true;
                string path = "", name = info.Device;
                for (uint index = 0; index < 64; index++)
                {
                    var device = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>(), Name = "", Description = "", ID = "", Key = "" };
                    if (!EnumDisplayDevices(info.Device, index, ref device, 1)) break;
                    if ((device.Flags & 1) == 0) continue;
                    path = device.ID; name = device.Description; break;
                }
                name = new string(name.Where(value => !char.IsControl(value)).Take(128).ToArray());
                found.Add(new(monitor, path, name.Length == 0 ? info.Device : name, info.Device, info.Bounds, info.Work, (info.Flags & 1) != 0));
                return true;
            }
            if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Read, IntPtr.Zero)) found.Clear();
            var next = found.OrderByDescending(value => value.Primary).ThenBy(value => value.Bounds.Left).ThenBy(value => value.Bounds.Top).ToArray();
            if (Current.SequenceEqual(next)) return;
            Current = Array.AsReadOnly(next); Changed?.Invoke();
        }
        finally { queued = false; }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; SystemEvents.DisplaySettingsChanged -= DisplayChanged;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        internal int Size; internal ScreenRectangle Bounds, Work; internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string Device;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        internal int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Description;
        internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string ID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Key;
    }
    private delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref ScreenRectangle rectangle, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo value);
    [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice value, uint flags);
}
