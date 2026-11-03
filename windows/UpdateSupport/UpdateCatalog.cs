using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace CodexPacer.Windows;

internal static class WindowsUpdateVersion
{
    internal static Version Read(Assembly assembly) => Version.TryParse(assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version, out var value)
        ? value : throw new InvalidDataException("The Windows build version is unavailable.");
}

internal sealed record WindowsUpdateChannel(Uri Feed, string PublicKey, string? SignerSHA256, Guid? TestScope = null, string? TestCertificateSHA256 = null, Version? TestCurrentBuild = null)
{
    internal bool Allows(Uri uri) => uri.IsAbsoluteUri && uri.AbsoluteUri.Length <= 4096 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 &&
        uri.Scheme == "https" && (TestScope == null || uri.Host == "127.0.0.1");
    internal void Validate()
    {
        if (!Allows(Feed) || Convert.FromBase64String(PublicKey).Length != 32 ||
            SignerSHA256 != null && (SignerSHA256.Length != 64 || !SignerSHA256.All(Uri.IsHexDigit)) ||
            TestScope == null && (TestCurrentBuild != null || TestCertificateSHA256 != null) ||
            TestScope != null && (TestCertificateSHA256?.Length != 64 || !TestCertificateSHA256.All(Uri.IsHexDigit)))
            throw new InvalidDataException("The Windows update channel is invalid.");
    }
    // Production endpoints and trust are intentionally unconfigured. They need
    // a separate authorized provisioning change; no Mac update value is read.
    internal static WindowsUpdateChannel? Production => null;
    internal static WindowsUpdateChannel ReadTest(string path, Guid scope)
    {
        using var doc = JsonDocument.Parse(UpdateFiles.Read(path, 4096));
        var root = doc.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1 || root.GetProperty("testScope").GetGuid() != scope)
            throw new InvalidDataException("The test channel must match its isolated application scope.");
        var result = new WindowsUpdateChannel(new Uri(root.GetProperty("feed").GetString()!, UriKind.Absolute),
            root.GetProperty("publicKey").GetString()!,
            root.TryGetProperty("signerSHA256", out var signer) && signer.ValueKind != JsonValueKind.Null ? signer.GetString() : null,
            scope, root.GetProperty("testCertificateSHA256").GetString()!,
            root.TryGetProperty("testCurrentBuild", out var build) ? Version.Parse(build.GetString()!) : null);
        result.Validate(); return result;
    }
}

internal sealed record WindowsUpdatePackage(string Version, Version Build, string Architecture, Version MinimumWindows,
    Uri Download, long Length, string Signature, string Notes);

internal static class UpdateCatalog
{
    internal const int FeedLimit = 1024 * 1024;
    internal const int PackageLimit = 256 * 1024 * 1024;
    internal const string SignaturePrefix = "<!-- pacer-feed-ed25519:";
    internal static readonly XNamespace Sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    internal static bool Verify(byte[] bytes, string signature, string key)
    {
        try
        {
            byte[] sig = Convert.FromBase64String(signature), pub = Convert.FromBase64String(key);
            if (sig.Length != 64 || pub.Length != 32) return false;
            var verifier = new Ed25519Signer(); verifier.Init(false, new Ed25519PublicKeyParameters(pub));
            verifier.BlockUpdate(bytes, 0, bytes.Length); return verifier.VerifySignature(sig);
        }
        catch (Exception error) when (error is FormatException or ArgumentException) { return false; }
    }
    internal static WindowsUpdatePackage? Parse(byte[] signedFeed, WindowsUpdateChannel channel, string architecture,
        Version currentBuild, Version windows, string language)
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
        if (!Verify(xml, signature, channel.PublicKey)) throw new InvalidDataException("The update feed signature is invalid.");
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
                !Version.TryParse(display, out _) || build <= currentBuild || minimum > windows) continue;
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
    // WinSparkle sees only verified, compatible metadata and a loopback payload.
    // Remote HTML and unsigned release-note links are never passed through.
    internal static byte[] Project(WindowsUpdatePackage? item, Uri? download)
    {
        var channel = new XElement("channel", new XElement("title", "Codex Pacer"));
        if (item != null && download != null)
            channel.Add(new XElement("item", new XElement("title", item.Version),
                new XElement(Sparkle + "version", item.Build), new XElement(Sparkle + "shortVersionString", item.Version),
                new XElement(Sparkle + "minimumSystemVersion", item.MinimumWindows),
                new XElement("description", new XCData("<pre>" + WebUtility.HtmlEncode(item.Notes) + "</pre>")),
                new XElement("enclosure", new XAttribute("url", download), new XAttribute("length", item.Length),
                    new XAttribute("type", "application/octet-stream"), new XAttribute(Sparkle + "os", "windows-" + item.Architecture),
                    new XAttribute(Sparkle + "edSignature", item.Signature))));
        return Encoding.UTF8.GetBytes(new XDocument(new XElement("rss", new XAttribute("version", "2.0"),
            new XAttribute(XNamespace.Xmlns + "sparkle", Sparkle), channel)).ToString(SaveOptions.DisableFormatting));
    }
}
