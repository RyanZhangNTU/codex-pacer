using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexPacer.Windows;

internal readonly record struct MotionBounds(double X, double Y, double Width, double Height);
internal readonly record struct MotionFrame(MotionBounds Bounds, MotionBounds Window, double Expansion,
    double Content, double BlackOpacity, bool Finished, double WidthVelocity, double HeightVelocity, double ExpansionVelocity);

/// <summary>Calls the original macOS Swift spring, without a second C# curve.</summary>
internal sealed class NativeMotion : IDisposable
{
    private static readonly object ModuleLock = new();
    private static Library? sharedLibrary;
    private static string? sharedPath;
    private readonly Library library;
    private readonly Motion handle;
    private readonly Retarget retarget;
    private readonly Sample sample;
    private readonly Canvas canvas;
    private readonly double[] buffer = new double[17];

    internal NativeMotion(string directory, MotionBounds initial, bool expanded = false, bool blackHeader = false, int position = 0)
    {
        library = GetLibrary(directory);
        if (Export<Version>("pacer_motion_abi_version")() != 1) throw new InvalidDataException("Animation ABI mismatch.");
        var create = Export<Create>("pacer_motion_create");
        var destroy = Export<Destroy>("pacer_motion_destroy");
        retarget = Export<Retarget>("pacer_motion_retarget");
        sample = Export<Sample>("pacer_motion_sample");
        canvas = Export<Canvas>("pacer_motion_canvas");
        IntPtr motion = create(initial.X, initial.Y, initial.Width, initial.Height, expanded ? 1 : 0, blackHeader ? 1 : 0, position);
        if (motion == IntPtr.Zero) throw new ArgumentOutOfRangeException(nameof(initial));
        handle = new Motion(motion, destroy, library);
    }

    private static Library GetLibrary(string directory)
    {
        string path = Path.GetFullPath(Path.Combine(directory, "PacerWindowsBridge.dll"));
        // Swift metadata and its runtime stay loaded for this process. Calling
        // FreeLibrary while the CLR remains active blocks in runtime teardown.
        // Reuse one module; individual transitions still release their objects.
        lock (ModuleLock)
        {
            if (sharedLibrary == null)
            {
                var value = new Library(LoadLibraryExW(path, IntPtr.Zero, 0x100 | 0x1000));
                if (value.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "The shared animation core could not load.");
                sharedLibrary = value; sharedPath = path;
            }
            else if (!string.Equals(sharedPath, path, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The animation module cannot change during a launch.");
            return sharedLibrary;
        }
    }

    internal void RetargetTo(MotionBounds target, bool expanded, double time, bool blackHeader = false, int position = 0)
    {
        ObjectDisposedException.ThrowIf(handle.IsClosed, this);
        bool reference = false;
        try
        {
            handle.DangerousAddRef(ref reference);
            if (retarget(handle.DangerousGetHandle(), target.X, target.Y, target.Width, target.Height, expanded ? 1 : 0, blackHeader ? 1 : 0, position, time) != 1)
                throw new ArgumentOutOfRangeException(nameof(target));
        }
        finally { if (reference) handle.DangerousRelease(); }
    }

    internal MotionFrame At(double time)
    {
        ObjectDisposedException.ThrowIf(handle.IsClosed, this);
        bool reference = false;
        try
        {
            handle.DangerousAddRef(ref reference);
            if (sample(handle.DangerousGetHandle(), time, buffer, buffer.Length) != 1) throw new ArgumentOutOfRangeException(nameof(time));
        }
        finally { if (reference) handle.DangerousRelease(); }
        return new(new(buffer[0], buffer[1], buffer[2], buffer[3]), new(buffer[13], buffer[14], buffer[15], buffer[16]),
            buffer[4], buffer[5], buffer[6], buffer[7] != 0, buffer[8], buffer[9], buffer[12]);
    }

    public void Dispose() => handle.Dispose();
    internal MotionBounds CanvasAt(double time)
    {
        ObjectDisposedException.ThrowIf(handle.IsClosed, this);
        bool reference = false; double[] bounds = new double[4];
        try
        {
            handle.DangerousAddRef(ref reference);
            if (canvas(handle.DangerousGetHandle(), time, bounds, bounds.Length) != 1) throw new ArgumentOutOfRangeException(nameof(time));
        }
        finally { if (reference) handle.DangerousRelease(); }
        return new(bounds[0], bounds[1], bounds[2], bounds[3]);
    }
    private T Export<T>(string name) where T : Delegate
    {
        IntPtr address = GetProcAddress(library, name);
        if (address == IntPtr.Zero) throw new InvalidDataException("The shared animation core has an incomplete ABI.");
        return Marshal.GetDelegateForFunctionPointer<T>(address);
    }
    internal static T SharedExport<T>(string directory, string name) where T : Delegate
    {
        IntPtr address = GetProcAddress(GetLibrary(directory), name);
        if (address == IntPtr.Zero) throw new InvalidDataException("The shared presentation core has an incomplete ABI.");
        return Marshal.GetDelegateForFunctionPointer<T>(address);
    }

    private sealed class Library : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal Library(IntPtr value) : base(false) => SetHandle(value);
        protected override bool ReleaseHandle() => true;
    }
    private sealed class Motion : SafeHandleZeroOrMinusOneIsInvalid
    {
        private readonly Destroy destroy;
        private readonly Library library;
        internal Motion(IntPtr value, Destroy destroy, Library library) : base(true)
        {
            this.destroy = destroy; this.library = library;
            bool added = false;
            library.DangerousAddRef(ref added);
            SetHandle(value);
        }
        protected override bool ReleaseHandle() { destroy(handle); library.DangerousRelease(); return true; }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Version();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr Create(double x, double y, double width, double height, int expanded, int black, int position);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Destroy(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Retarget(IntPtr handle, double x, double y, double width, double height, int expanded, int black, int position, double time);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Sample(IntPtr handle, double time, [Out] double[] buffer, int capacity);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Canvas(IntPtr handle, double time, [Out] double[] buffer, int capacity);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)] private static extern IntPtr GetProcAddress(Library library, string name);
}
