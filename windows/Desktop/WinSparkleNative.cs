using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

namespace CodexPacer.Windows;

internal enum UpdateBackendEvent { Found, NoUpdate, Failed, Dismissed }
internal interface IWindowsUpdateBackend : IDisposable
{
    event Action<UpdateBackendEvent, long>? Changed;
    Func<string, bool>? Install { get; set; }
    void Initialize(Uri feed, string key, string version, string build, string language, bool automatic);
    void Check(Uri feed, bool interactive, long context);
    void SetAutomatic(bool value);
}

internal sealed class WinSparkleNative : IWindowsUpdateBackend
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Empty();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Text([MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void WideText([MarshalAs(UnmanagedType.LPWStr)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Key([MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Number(int value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Pointer(IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Ready();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Installer(IntPtr path);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Details([MarshalAs(UnmanagedType.LPWStr)] string company, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string version);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ReadConfig(IntPtr name, IntPtr buffer, nuint length, IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void WriteConfig(IntPtr name, IntPtr value, IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void DeleteConfig(IntPtr name, IntPtr context);
    [StructLayout(LayoutKind.Sequential)] private struct Config { internal IntPtr Read, Write, Delete, Context; }
    private readonly IntPtr library;
    private readonly WindowsUpdateState state;
    private readonly List<Delegate> roots = [];
    private readonly object api = new();
    private IntPtr config;
    private bool initialized, disposed;
    private bool suppress;
    private (string Key, string Version, string Build, string Language, bool Automatic)? options;
    private int configFailure;
    private long operationContext;
    public event Action<UpdateBackendEvent, long>? Changed;
    public Func<string, bool>? Install { get; set; }
    internal WinSparkleNative(string directory, WindowsUpdateState state)
    {
        this.state = state;
        string file = Path.Combine(directory, "WinSparkle.dll");
        string expected = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "9b43b1c16ee39fb9a91b5bd75138767898779510e0836be2919250607cdbe8ab",
            Architecture.Arm64 => "f38829a6b1ef853b9bed780e9e40614c100e0a3020318555c9f6681deade5756",
            _ => throw new PlatformNotSupportedException()
        };
        if (Convert.ToHexStringLower(SHA256.HashData(UpdateFiles.Read(file, 8 * 1024 * 1024))) != expected) throw new InvalidDataException("The pinned updater is unavailable.");
        library = LoadLibraryExW(Path.GetFullPath(file), IntPtr.Zero, 0x100 | 0x1000);
        if (library == IntPtr.Zero) throw new IOException("The updater could not load.");
    }
    private T Export<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, "win_sparkle_" + name));
    private IntPtr Root(Delegate value) { roots.Add(value); return Marshal.GetFunctionPointerForDelegate(value); }
    private void Callback(string name, Delegate callback) => Export<Pointer>("set_" + name + "_callback")(Root(callback));
    private void Notify(UpdateBackendEvent value, long context) { try { if (!suppress) Changed?.Invoke(value, context); } catch { /* No exception may cross a C callback. */ } }
    public void Initialize(Uri feed, string key, string version, string build, string language, bool automatic)
    { lock (api) { options = (key, version, build, language, automatic); InitializeCore(feed, key, version, build, language, automatic); } }
    private void InitializeCore(Uri feed, string key, string version, string build, string language, bool automatic)
    {
        if (initialized || disposed) throw new InvalidOperationException();
        long context = Interlocked.Read(ref operationContext);
        ReadConfig read = (name, buffer, length, _) =>
        {
            try
            {
                string? value = state.Read(Marshal.PtrToStringUTF8(name) ?? "");
                if (value == null || (nuint)(value.Length + 1) > length) return 0;
                Marshal.Copy((value + "\0").ToCharArray(), 0, buffer, value.Length + 1); return 1;
            }
            catch { Interlocked.Exchange(ref configFailure, 1); Notify(UpdateBackendEvent.Failed, context); return 0; }
        };
        WriteConfig write = (name, value, _) => { try { state.Write(Marshal.PtrToStringUTF8(name) ?? "", Marshal.PtrToStringUni(value) ?? ""); } catch { Interlocked.Exchange(ref configFailure, 1); Notify(UpdateBackendEvent.Failed, context); } };
        DeleteConfig delete = (name, _) => { try { state.Write(Marshal.PtrToStringUTF8(name) ?? "", null); } catch { Interlocked.Exchange(ref configFailure, 1); Notify(UpdateBackendEvent.Failed, context); } };
        var methods = new Config { Read = Root(read), Write = Root(write), Delete = Root(delete) };
        config = Marshal.AllocHGlobal(Marshal.SizeOf<Config>()); Marshal.StructureToPtr(methods, config, false);
        Export<Pointer>("set_config_methods")(config);
        Callback("error", (Empty)(() => Notify(UpdateBackendEvent.Failed, context)));
        Callback("did_find_update", (Empty)(() => Notify(UpdateBackendEvent.Found, context)));
        Callback("did_not_find_update", (Empty)(() => Notify(UpdateBackendEvent.NoUpdate, context)));
        foreach (string name in new[] { "update_dismissed", "update_cancelled", "update_skipped", "update_postponed" })
            Callback(name, (Empty)(() => Notify(UpdateBackendEvent.Dismissed, context)));
        Callback("can_shutdown", (Ready)(() => 1));
        Callback("shutdown_request", (Empty)(() => { })); // The owned helper waits for normal host shutdown.
        Callback("user_run_installer", (Installer)(path =>
        {
            try { if (context != Interlocked.Read(ref operationContext)) return -1; return Install?.Invoke(Marshal.PtrToStringUni(path) ?? "") == true ? 1 : -1; }
            catch { Notify(UpdateBackendEvent.Failed, context); return -1; }
        }));
        Export<Details>("set_app_details")("Codex Pacer", "Codex Pacer", version);
        Export<WideText>("set_app_build_version")(build);
        Export<Text>("set_lang")(language == "zh-Hans" ? "zh_CN" : "en");
        Export<Text>("set_appcast_url")(feed.AbsoluteUri);
        if (Export<Key>("set_eddsa_public_key")(key) == 0) throw new InvalidDataException("The update signature key is invalid.");
        Export<Number>("set_update_check_interval")(86400);
        SetAutomatic(automatic); Export<Empty>("init")(); initialized = true;
    }
    internal bool ValidateKey(string key) { lock (api) { return Export<Key>("set_eddsa_public_key")(key) != 0; } }
    public void Check(Uri feed, bool interactive, long context)
    {
        lock (api)
        {
            if (disposed || options == null) throw new InvalidOperationException();
            Interlocked.Exchange(ref operationContext, context);
            StopSDK(); var current = options.Value;
            InitializeCore(feed, current.Key, current.Version, current.Build, current.Language, current.Automatic);
            Export<Empty>(interactive ? "check_update_with_ui" : "check_update_without_ui")();
        }
    }
    public void SetAutomatic(bool value)
    {
        lock (api)
        {
            if (disposed) throw new ObjectDisposedException(nameof(WinSparkleNative));
            Interlocked.Exchange(ref configFailure, 0);
            state.Write("PacerAutomaticChecks", value ? "1" : "0");
            if (options is { } saved) options = (saved.Key, saved.Version, saved.Build, saved.Language, value);
            // The host schedules daily checks so a proxy exists only for an
            // owned update operation. WinSparkle never polls an inactive URL.
            Export<Number>("set_automatic_check_for_updates")(0);
            if (Volatile.Read(ref configFailure) != 0) throw new IOException("The update preference could not be saved.");
        }
    }
    public void Dispose()
    { lock (api) { DisposeCore(); } }
    private void DisposeCore()
    {
        if (disposed) return; disposed = true;
        StopSDK(); NativeLibrary.Free(library);
    }
    private void StopSDK()
    {
        suppress = true;
        try { if (initialized) Export<Empty>("cleanup")(); }
        finally
        {
            initialized = false;
            if (config != IntPtr.Zero) Marshal.FreeHGlobal(config);
            config = IntPtr.Zero; roots.Clear(); suppress = false;
        }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
}
