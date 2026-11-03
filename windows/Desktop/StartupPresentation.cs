namespace CodexPacer.Windows;

internal sealed record StartupPresentation(string? Guide, string? Failure)
{
    internal int WindowCount => Guide == null ? 0 : 1;
    // Installed feed notes are available only through an explicit signed read.
    internal static StartupPresentation Resolve(GuideCatalog? catalog, UpdateInstallResult? installed)
        => new(catalog?.Page, installed is { Success: false } ? "windows.updates.install_failed" : null);
}
