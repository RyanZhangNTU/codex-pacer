using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace CodexPacer.Windows;

/// The user's time zone for the engine. Swift Foundation on Windows reports GMT,
/// so the host passes an IANA name, or the current UTC offset when Windows has
/// no IANA mapping for the zone.
internal static class EngineTimeZone
{
    private static readonly Regex Identifier = new(@"\A[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+){0,2}\z", RegexOptions.CultureInvariant);

    internal static (string Flag, string Value) Argument(TimeZoneInfo zone, DateTimeOffset now)
    {
        string? iana = zone.HasIanaId ? zone.Id : TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out var converted) ? converted : null;
        if (iana is { Length: <= 64 } && Identifier.IsMatch(iana)) return ("--time-zone", iana);
        int seconds = (int)Math.Round(zone.GetUtcOffset(now).TotalSeconds);
        return ("--time-zone-offset", seconds.ToString(CultureInfo.InvariantCulture));
    }
}
