using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using CodexPacer.Windows;

/// The feed parser exactly as Windows 4.2.2 shipped it (UpdateCatalog.Parse at
/// 98892af). Installed 4.2.2 clients read every later feed with this code, so
/// new feed content must leave its result unchanged. Do not modernize it.
internal static class Frozen422Catalog
{
    private const int FeedLimit = 1024 * 1024, PackageLimit = 256 * 1024 * 1024;
    private const string SignaturePrefix = "<!-- pacer-feed-ed25519:";
    private static readonly XNamespace Sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    internal static WindowsUpdatePackage? Parse(byte[] signedFeed, WindowsUpdateChannel channel, string architecture,
        Version currentBuild, Version windows, string language, bool notesForCurrentBuild = false)
    {
        channel.Validate();
        if (signedFeed.Length > FeedLimit || architecture is not ("x64" or "arm64")) throw new InvalidDataException("Invalid update feed.");
        int newline = Array.IndexOf(signedFeed, (byte)10);
        if (newline is < 0 or > 256) throw new InvalidDataException("The update feed must be signed.");
        string header = Encoding.ASCII.GetString(signedFeed, 0, newline);
        if (!header.StartsWith(SignaturePrefix, StringComparison.Ordinal) || !header.EndsWith(" -->", StringComparison.Ordinal))
            throw new InvalidDataException("The update feed must be signed.");
        byte[] xml = signedFeed.AsSpan(newline + 1).ToArray();
        string signature = header[SignaturePrefix.Length..^4];
        if (!UpdateCatalog.Verify(xml, signature, channel.PublicKey)) throw new InvalidDataException("The update feed signature is invalid.");
        using var stream = new MemoryStream(xml, writable: false);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = FeedLimit });
        var doc = XDocument.Load(reader);
        if (doc.Root?.Name != "rss" || doc.Root.Elements("channel").Count() != 1) throw new InvalidDataException("Invalid update feed.");
        var items = doc.Root.Element("channel")!.Elements("item").ToArray();
        if (items.Length > 128) throw new InvalidDataException("Too many update entries.");
        WindowsUpdatePackage? selected = null;
        foreach (var item in items)
        {
            var enclosures = item.Elements("enclosure").ToArray();
            if (enclosures.Length != 1) throw new InvalidDataException("Invalid update enclosure.");
            var enclosure = enclosures[0];
            if ((string?)enclosure.Attribute(Sparkle + "os") != "windows-" + architecture) continue;
            string Required(XName name)
            {
                var values = item.Elements(name).ToArray();
                if (values.Length != 1 || values[0].Value.Length > 128) throw new InvalidDataException("Invalid update metadata.");
                return values[0].Value;
            }
            string buildText = Required(Sparkle + "version"), display = Required(Sparkle + "shortVersionString");
            if (!Version.TryParse(buildText, out var build) || build.Revision < 0 ||
                !Version.TryParse(Required(Sparkle + "minimumSystemVersion"), out var minimum) || minimum.Build < 0 ||
                !Version.TryParse(display, out _) || (notesForCurrentBuild ? build != currentBuild : build <= currentBuild) || minimum > windows) continue;
            if (!Uri.TryCreate((string?)enclosure.Attribute("url"), UriKind.Absolute, out var url) || !channel.Allows(url) ||
                !long.TryParse((string?)enclosure.Attribute("length"), NumberStyles.None, CultureInfo.InvariantCulture, out long length) || length is <= 0 or > PackageLimit)
                throw new InvalidDataException("Invalid update download.");
            string payloadSignature = (string?)enclosure.Attribute(Sparkle + "edSignature") ?? "";
            if (Convert.FromBase64String(payloadSignature).Length != 64) throw new InvalidDataException("Invalid update signature.");
            string notes = item.Elements("description").FirstOrDefault(value => (string?)value.Attribute(XNamespace.Xml + "lang") == language)?.Value
                ?? item.Elements("description").FirstOrDefault(value => (string?)value.Attribute(XNamespace.Xml + "lang") is null or "en")?.Value ?? "";
            if (Encoding.UTF8.GetByteCount(notes) > 128 * 1024) throw new InvalidDataException("Update notes exceed their limit.");
            var candidate = new WindowsUpdatePackage(display, build, architecture, minimum, url, length, payloadSignature, notes);
            if (selected == null || build > selected.Build) selected = candidate;
        }
        return selected;
    }
}
