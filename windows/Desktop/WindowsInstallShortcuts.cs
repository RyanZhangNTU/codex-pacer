using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;
using System.Text;

namespace CodexPacer.Windows;

internal interface IInstallationShortcut
{
    void Create(string path, string executable);
    string? Target(string path);
}
internal sealed class WindowsInstallShortcuts : IInstallationShortcut
{
    public void Create(string path, string executable)
    {
        WindowsInstallationIdentity.RequireNoReparse(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".pacer-" + Guid.NewGuid().ToString("N");
        object instance = new ShellLink();
        try
        {
            var link = (IShellLinkW)instance;
            link.SetPath(executable); link.SetArguments("");
            link.SetWorkingDirectory(Path.GetDirectoryName(executable)!);
            link.SetDescription("Codex Pacer"); link.SetShowCmd(1);
            link.SetIconLocation(Path.Combine(Path.GetDirectoryName(executable)!, "Assets", "Pacer.ico"), 0);
            ((IPersistFile)instance).Save(temporary, true);
            File.Move(temporary, path, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(instance);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
    public string? Target(string path)
    {
        if (!File.Exists(path)) return null;
        WindowsInstallationIdentity.RequireNoReparse(path);
        object instance = new ShellLink();
        try
        {
            ((IPersistFile)instance).Load(path, 0);
            var target = new StringBuilder(32768); var args = new StringBuilder(4096);
            ((IShellLinkW)instance).GetPath(target, target.Capacity, IntPtr.Zero, 4);
            ((IShellLinkW)instance).GetArguments(args, args.Capacity);
            return args.Length == 0 && Path.IsPathFullyQualified(target.ToString()) ? Path.GetFullPath(target.ToString()) : null;
        }
        catch (Exception error) when (error is COMException or IOException or ArgumentException) { return null; }
        finally { Marshal.FinalReleaseComObject(instance); }
    }
    internal static string? Digest(string path)
    {
        if (!File.Exists(path)) return null;
        WindowsInstallationIdentity.RequireNoReparse(path);
        return Convert.ToHexString(SHA256.HashData(WindowsInstallationIdentity.ReadBounded(path, 256 * 1024)));
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] private class ShellLink { }
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int count, IntPtr data, uint flags);
        void GetIDList(out IntPtr value); void SetIDList(IntPtr value);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetHotkey(out short value); void SetHotkey(short value);
        void GetShowCmd(out int value); void SetShowCmd(int value);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string value, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
    }
}
