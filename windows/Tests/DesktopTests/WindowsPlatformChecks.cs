using System.Runtime.InteropServices;
using CodexPacer.Windows;

internal static class WindowsPlatformChecks
{
    internal static void Run()
    {
        var now = new DateTimeOffset(2027, 1, 15, 8, 0, 0, TimeSpan.Zero);
        var summer = new DateTimeOffset(2027, 7, 15, 8, 0, 0, TimeSpan.Zero);
        var china = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
        var eastern = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
        Check(Arguments(china, now, null) == "--time-zone Asia/Shanghai --time-zone-offset 28800"
            && Arguments(eastern, now, "US") == "--time-zone America/New_York --time-zone-offset -18000"
            && Arguments(eastern, summer, "US") == "--time-zone America/New_York --time-zone-offset -14400",
            "Windows zones reach the engine as IANA names with their own DST rules, and always with the current offset in case the name can't load");
        Check(Arguments(china, now, "HK") == "--time-zone Asia/Hong_Kong --time-zone-offset 28800"
            && Arguments(china, now, "CN") == "--time-zone Asia/Shanghai --time-zone-offset 28800"
            && Arguments(china, now, "US") == "--time-zone Asia/Shanghai --time-zone-offset 28800"
            && Arguments(china, now, "PRIVATE") == "--time-zone Asia/Shanghai --time-zone-offset 28800",
            "The Windows region picks a zone's own IANA name, and any other region keeps the zone's default name");
        var custom = TimeZoneInfo.CreateCustomTimeZone("Pacer Synthetic Zone", TimeSpan.FromMinutes(345), "Synthetic", "Synthetic");
        Check(Arguments(custom, now, "US") == "--time-zone-offset 20700", "A zone without an IANA name falls back to its current offset");
        // How Windows builds the local zone when automatic daylight saving time is off.
        var easternWithoutDST = TimeZoneInfo.CreateCustomTimeZone("Eastern Standard Time", TimeSpan.FromHours(-5), "Eastern", "Eastern");
        Check(Arguments(easternWithoutDST, summer, "US") == "--time-zone-offset -18000",
            "Without automatic daylight saving time the engine keeps the standard offset all year, as the Windows clock does");
        Check(EngineTimeZone.Region() is null or { Length: 2 }, "The region is a two-letter code when Windows has one");
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
    private static string Arguments(TimeZoneInfo zone, DateTimeOffset now, string? region) => string.Join(' ', EngineTimeZone.Arguments(zone, now, region));
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
