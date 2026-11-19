using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security;
using System.Text.RegularExpressions;

namespace CodexPacer.Windows;

/// The user's time zone for the engine. Swift Foundation on Windows reports GMT,
/// so the host passes the zone's IANA name and its current UTC offset. The engine
/// prefers the name, for its daylight saving rules, and keeps the offset when it
/// can't load the name or none is passed.
internal static class EngineTimeZone
{
    private static readonly Regex Identifier = new(@"\A[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+){0,2}\z", RegexOptions.CultureInvariant);

    internal static IReadOnlyList<string> Arguments(TimeZoneInfo zone, DateTimeOffset now, string? region)
    {
        var arguments = new List<string>(4);
        // With "Adjust for daylight saving time automatically" off, Windows keeps
        // the standard offset all year, which the zone's name would not.
        if (!DaylightSavingTurnedOff(zone) && IanaName(zone, region) is { } name) { arguments.Add("--time-zone"); arguments.Add(name); }
        int seconds = (int)Math.Round(zone.GetUtcOffset(now).TotalSeconds);
        arguments.Add("--time-zone-offset"); arguments.Add(seconds.ToString(CultureInfo.InvariantCulture));
        return arguments;
    }

    /// The Windows "Country or region" setting, which picks among a zone's IANA
    /// names: Hong Kong within China Standard Time, for example.
    internal static string? Region()
    {
        try { return RegionInfo.CurrentRegion.TwoLetterISORegionName is { Length: 2 } code && char.IsAsciiLetter(code[0]) && char.IsAsciiLetter(code[1]) ? code : null; }
        catch (ArgumentException) { return null; }
    }

    private static string? IanaName(TimeZoneInfo zone, string? region)
    {
        string? name = zone.HasIanaId ? zone.Id
            : region is { Length: 2 } && TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, region, out var regional) ? regional
            : TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out var converted) ? converted : null;
        return name is { Length: <= 64 } && Identifier.IsMatch(name) ? name : null;
    }

    /// Windows then builds the local zone without the daylight saving rules its
    /// system zone of the same ID has.
    private static bool DaylightSavingTurnedOff(TimeZoneInfo zone)
    {
        if (zone.SupportsDaylightSavingTime || zone.HasIanaId) return false;
        try { return TimeZoneInfo.FindSystemTimeZoneById(zone.Id).SupportsDaylightSavingTime; }
        catch (Exception error) when (error is TimeZoneNotFoundException or InvalidTimeZoneException or SecurityException) { return false; }
    }
}
