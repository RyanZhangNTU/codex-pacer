using System.Runtime.InteropServices;
using CodexPacer.Windows;

internal static class WindowsPlatformChecks
{
    internal static void Run()
    {
        Check(!WindowsPlatformPolicy.Supports(6, 19041) && !WindowsPlatformPolicy.Supports(10, 19040)
            && WindowsPlatformPolicy.Supports(10, 19041) && WindowsPlatformPolicy.Supports(10, 19045)
            && WindowsPlatformPolicy.Supports(10, 22000), "The minimum build includes Windows 10 and early Windows 11 without enabling glass");
        int probes = 0;
        bool Probe() { probes++; return true; }
        Check(!WindowsPlatformPolicy.NotificationsSupported(19040, Probe) && probes == 0, "Unsupported builds never call the notification API");
        Check(WindowsPlatformPolicy.NotificationsSupported(19041, Probe) && probes == 1, "Supported Windows 10 builds probe the actual capability");
        Check(!WindowsPlatformPolicy.NotificationsSupported(19041, () => false), "A supported OS can still lack the notification capability");
        foreach (Exception failure in new Exception[] { new COMException(), new TypeLoadException(), new DllNotFoundException(),
            new EntryPointNotFoundException(), new MissingMethodException(), new NotSupportedException(), new InvalidOperationException() })
            Check(!WindowsPlatformPolicy.NotificationsSupported(19041, () => throw failure), "Unavailable notification APIs fail closed");
        foreach (int build in new[] { 19041, 19045, 22000, 22620 })
        {
            var state = new Source { Current = new(build, true, false) }; int surfaces = 0;
            using var controller = new BackdropController(state, () => { surfaces++; throw new Exception("Must not create a glass surface"); }, action => action());
            controller.Prefer("liquidGlass"); controller.Apply(new(0, 0, 200, 40, 1, [0, 0, 200, 0, 200, 40], true));
            Check(surfaces == 0 && !controller.Glass && controller.Decision.Preferred == "liquidGlass"
                && controller.Decision.Reason == BackdropReason.OldSystem, "Windows 10 and early Windows 11 keep the preference and never load the glass DLL");
        }
    }
    private sealed class Source : IBackdropSystemSource
    {
        public BackdropSystemState Current { get; init; }
        public event Action? Changed { add { } remove { } }
        public void Dispose() { }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
