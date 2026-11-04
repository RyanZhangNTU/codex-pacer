using System.Net;
using System.Security.Cryptography;
using System.Reflection;
using System.Reflection.Emit;
using System.Text;
using System.Xml.Linq;
using CodexPacer.Windows;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

internal static class WindowsUpdateChecks
{
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class SigningFixture
    {
        private readonly Ed25519PrivateKeyParameters key = new(new SecureRandom());
        internal string Public => Convert.ToBase64String(key.GeneratePublicKey().GetEncoded());
        internal string Sign(byte[] bytes)
        {
            var signer = new Ed25519Signer(); signer.Init(true, key); signer.BlockUpdate(bytes, 0, bytes.Length);
            return Convert.ToBase64String(signer.GenerateSignature());
        }
        internal byte[] Feed(params XElement[] items)
        {
            byte[] xml = Encoding.UTF8.GetBytes(new XDocument(new XElement("rss", new XAttribute("version", "2.0"), new XElement("channel", items))).ToString());
            return Encoding.ASCII.GetBytes(UpdateCatalog.SignaturePrefix + Sign(xml) + " -->\n").Concat(xml).ToArray();
        }
    }
    private static readonly Version Current = new(1, 2, 3, 4), Windows = new(10, 0, 19041);
    private static readonly byte[] Payload = Encoding.UTF8.GetBytes("synthetic unsigned installer, never executed");
    private static XElement Item(SigningFixture key, string arch = "x64", string build = "1.2.3.5", string minimum = "10.0.19041", string? download = null)
    {
        XNamespace sparkle = UpdateCatalog.Sparkle;
        return new XElement("item", new XElement(sparkle + "version", build), new XElement(sparkle + "shortVersionString", "1.2.3"),
            new XElement(sparkle + "minimumSystemVersion", minimum),
            new XElement("description", new XAttribute(XNamespace.Xml + "lang", "en"), "Synthetic English notes"),
            new XElement("description", new XAttribute(XNamespace.Xml + "lang", "zh-Hans"), "合成中文说明"),
            new XElement(sparkle + "releaseNotesLink", "https://private.example/never-fetch"),
            new XElement("enclosure", new XAttribute("url", download ?? "https://127.0.0.1:9/setup.exe"),
                new XAttribute("length", Payload.Length), new XAttribute(sparkle + "os", "windows-" + arch), new XAttribute(sparkle + "edSignature", key.Sign(Payload))));
    }
    private static void Reject(Action action, string message)
    {
        try { action(); } catch (Exception error) when (error is IOException or InvalidDataException or FormatException or System.Xml.XmlException or ArgumentException) { return; }
        throw new InvalidOperationException(message);
    }
    private static async Task Fails<T>(Func<Task> action, string message) where T : Exception
    {
        try { await action(); } catch (T) { return; }
        throw new InvalidOperationException(message);
    }
    private sealed class Inline<T>(Action<T> action) : IProgress<T> { public void Report(T value) => action(value); }
    /// A package body with no Content-Length, read in 64 KiB steps, optionally paced.
    private sealed class Paced(byte[] bytes, TimeSpan pause) : Stream
    {
        private int position;
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => position; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (pause > TimeSpan.Zero) await Task.Delay(pause, cancellationToken);
            int count = Math.Min(Math.Min(buffer.Length, 64 * 1024), bytes.Length - position);
            bytes.AsMemory(position, count).CopyTo(buffer); position += count; return count;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
    /// A connection that opens and then never sends a byte.
    private sealed class Silent : Stream
    {
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        { await Task.Delay(Timeout.Infinite, cancellationToken); return 0; }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
    private sealed class Transport(byte[] feed) : HttpMessageHandler
    {
        internal byte[] Feed = feed;
        internal byte[]? Package;
        internal bool Fail, Corrupt, Stall, Unsized;
        internal TimeSpan Pause = TimeSpan.Zero;
        internal readonly List<Uri> Calls = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls.Add(request.RequestUri!);
            byte[] body = Package ?? Payload;
            HttpContent content = request.RequestUri!.AbsolutePath.EndsWith(".xml", StringComparison.Ordinal) ? new ByteArrayContent(Feed)
                : Corrupt ? new ByteArrayContent([1, 2, 3]) : Stall ? new StreamContent(new Silent())
                : Unsized || Pause > TimeSpan.Zero ? new StreamContent(new Paced(body, Pause)) : new ByteArrayContent(body);
            return Task.FromResult(new HttpResponseMessage(Fail ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK) { RequestMessage = request, Content = content });
        }
    }
    /// Absolute URLs answer with a body or a redirect; anything else is missing.
    private sealed class Routes : HttpMessageHandler
    {
        internal readonly Dictionary<string, Func<HttpResponseMessage>> Map = [];
        internal readonly List<Uri> Calls = [];
        internal void Redirect(string from, string to) => Map[from] = () => { var response = new HttpResponseMessage(HttpStatusCode.Found); response.Headers.Location = new Uri(to); return response; };
        internal void Serve(string at, byte[] body) => Map[at] = () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) };
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls.Add(request.RequestUri!);
            var response = Map.TryGetValue(request.RequestUri!.AbsoluteUri, out var reply) ? reply() : new HttpResponseMessage(HttpStatusCode.NotFound);
            response.RequestMessage = request; return Task.FromResult(response);
        }
    }
    private sealed class Presenter : IWindowsUpdatePresenter
    {
        internal readonly List<string> Events = [];
        public void Checking() => Events.Add("checking");
        public void Offer(WindowsUpdatePackage package, bool manual) => Events.Add((manual ? "offer:" : "auto-offer:") + package.Build);
        public void UpToDate() => Events.Add("up-to-date");
        public void Failed(bool manual) => Events.Add(manual ? "failed" : "auto-failed");
    }
    private static string Session(string root)
    {
        string directory = Path.Combine(root, "Updates", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory); return directory;
    }
    internal static async Task Run()
    {
        InstallerIdentityChecks();
        Check(UpdateHandoff.InstallerArguments(@"C:\Users\Synthetic 中文\Codex Pacer", @"C:\Users\Synthetic 中文\Updates\s\install.log", "zh-Hans").SequenceEqual(
            new[] { "/SP-", "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LANG=chinesesimplified", @"/LOG=C:\Users\Synthetic 中文\Updates\s\install.log", @"/DIR=C:\Users\Synthetic 中文\Codex Pacer" }),
            "An accepted update installs without wizard pages or prompts, in the app's language, logs beside its session, keeps each path as one argument and never restarts Windows");
        Check(UpdateHandoff.InstallerLanguage("en") == "english" && UpdateHandoff.InstallerLanguage("fr") == "english", "Other UI languages install in English");
        NotesChecks();
        string root = Path.Combine(Path.GetTempPath(), "Pacer update 中文 " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var key = new SigningFixture(); Guid scope = Guid.NewGuid();
            var channel = new WindowsUpdateChannel(new Uri("https://127.0.0.1:9/appcast.xml"), key.Public, null, scope, new string('a', 64));
            byte[] feed = key.Feed(Item(key), Item(key, "arm64", "1.2.3.6"));
            var item = UpdateCatalog.Parse(feed, channel, "x64", Current, Windows, "zh-Hans");
            Check(item is { Notes: "合成中文说明", Architecture: "x64" } && item.Build == new Version(1, 2, 3, 5), "Architecture and language select the signed compatible entry");
            Check(UpdateCatalog.Parse(feed, channel, "arm64", Current, Windows, "en")?.Build == new Version(1, 2, 3, 6), "ARM64 keeps its own signed update");
            Check(UpdateCatalog.Parse(feed, channel, "x64", new(1, 2, 3, 5), Windows, "en") == null, "Current/older builds cannot update");
            var notesTransport = new Transport(feed);
            using (var notes = new UpdateFeedClient(channel, "x64", new(1, 2, 3, 5), Windows, "zh-Hans", notesTransport))
            {
                Check(await notes.ReadReleaseNotesAsync() == "合成中文说明" && notesTransport.Calls.Count == 1,
                    "An explicit release-notes read verifies the current build and language without fetching a package");
                notesTransport.Feed = feed.ToArray(); notesTransport.Feed[^1] ^= 1;
                await Fails<InvalidDataException>(() => notes.ReadReleaseNotesAsync(), "Manual release notes reject a modified feed instead of reusing cached text");
            }
            Check(UpdateCatalog.Parse(feed, channel, "x64", new(1, 2, 3, 6), Windows, "en", notesForCurrentBuild: true) == null,
                "Manual release notes cannot borrow another installed build's description");
            Check(UpdateCatalog.Parse(key.Feed(Item(key, minimum: "10.0.22000")), channel, "x64", Current, Windows, "en") == null, "An incompatible minimum Windows build is excluded");
            Check(UpdateCatalog.Parse(key.Feed(Item(key, "macos")), channel, "x64", Current, Windows, "en") == null, "Mac packages cannot be selected");
            byte[] tampered = (byte[])feed.Clone(); tampered[^5] ^= 1;
            Reject(() => UpdateCatalog.Parse(tampered, channel, "x64", Current, Windows, "en"), "A modified signed feed must fail");
            Reject(() => UpdateCatalog.Parse(feed, channel with { PublicKey = new SigningFixture().Public }, "x64", Current, Windows, "en"), "A different isolated key must fail");
            Reject(() => UpdateCatalog.Parse(Encoding.UTF8.GetBytes("<rss/>"), channel, "x64", Current, Windows, "en"), "Unsigned feeds must fail");
            Reject(() => UpdateCatalog.Parse(key.Feed(Item(key, download: "https://not-loopback.example/setup.exe")), channel, "x64", Current, Windows, "en"), "QA cannot contact an external host");
            Reject(() => (channel with { TestScope = null }).Validate(), "Production cannot inherit a QA-only TLS certificate pin");
            Reject(() => UpdateCatalog.Parse(new byte[UpdateCatalog.FeedLimit + 1], channel, "x64", Current, Windows, "en"), "Feeds are bounded before parsing");
            var duplicate = Item(key); duplicate.Add(new XElement(UpdateCatalog.Sparkle + "version", "1.2.3.7"));
            Reject(() => UpdateCatalog.Parse(key.Feed(duplicate), channel, "x64", Current, Windows, "en"), "Duplicate version metadata must fail");
            await ClientChecks(key, channel, feed, root);
            await DeltaChecks(key, channel, root);
            await ServiceChecks(key, channel, feed, root);
            await HttpsChecks(key, channel, root);
            await ProductionChecks(key, root);
            await HandoffChecks();
            SignerPolicyChecks(key, channel, root);
            SessionChecks(root);
            StateChecks(root);
            string unsigned = Path.Combine(root, "unsigned.exe"); File.WriteAllBytes(unsigned, Payload);
            Check(!UpdateAuthenticode.Verify(unsigned, new string('0', 64)), "Production rejects unsigned installers without installing test trust");
            Console.WriteLine("PASS Windows updates: isolated signed feed/package, streamed verified download with progress, stall/cancel/tamper cleanup, redirects, skip/later/stale offers, session cleanup, rollback and once-only notes");
        }
        finally { Directory.Delete(root, recursive: true); }
    }
    private static void NotesChecks()
    {
        var blocks = ReleaseNotesMarkdown.Parse("Codex Pacer 4.2.2 comes to **Windows**.\r\n\r\n- **Codex Pacer for Windows.** The same island.\n* `/code-review` ends.\n\n### Install\n\n12. Run it\n" +
            "See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md), [elsewhere](https://example.com/x) and \\*not bold\\*.\n<script>alert(1)</script>");
        Check(blocks.Select(block => block.Kind).SequenceEqual([NoteBlockKind.Paragraph, NoteBlockKind.Bullet, NoteBlockKind.Bullet, NoteBlockKind.Heading, NoteBlockKind.Numbered, NoteBlockKind.Paragraph]),
            "Release notes keep their paragraphs, lists and headings");
        Check(blocks[0].Spans.Select(span => (span.Kind, span.Text)).SequenceEqual([(NoteSpanKind.Text, "Codex Pacer 4.2.2 comes to "), (NoteSpanKind.Strong, "Windows"), (NoteSpanKind.Text, ".")])
            && blocks[2].Spans[0] == new NoteSpan(NoteSpanKind.Code, "/code-review") && blocks[3] is { Level: 3 } && blocks[4].Number == 12,
            "Strong text, code, heading levels and list numbers survive");
        var links = blocks[5].Spans;
        Check(links.Any(span => span is { Kind: NoteSpanKind.Link, Text: "user guide", Link.Host: "github.com" })
            && links.Any(span => span is { Kind: NoteSpanKind.Text, Text: "elsewhere" }) && !links.Any(span => span.Link?.Host == "example.com"),
            "Only GitHub HTTPS links stay links; other targets become plain text");
        string text = string.Concat(links.Select(span => span.Text));
        Check(text.Contains("*not bold*") && text.Contains("<script>alert(1)</script>"), "Escapes and HTML stay literal text");
        Check(ReleaseNotesMarkdown.Parse(string.Join("\n\n", Enumerable.Repeat("p", 600))).Count == ReleaseNotesMarkdown.MaximumBlocks && ReleaseNotesMarkdown.Parse(null).Count == 0,
            "Notes are bounded and empty notes have no blocks");
    }
    private static async Task ClientChecks(SigningFixture key, WindowsUpdateChannel channel, byte[] feed, string root)
    {
        var transport = new Transport(feed);
        using var client = new UpdateFeedClient(channel, "x64", Current, Windows, "zh-Hans", transport, TimeSpan.FromMilliseconds(300));
        var offer = (await client.ReadOfferAsync())!;
        Check(offer is { Notes: "合成中文说明", Architecture: "x64" } && offer.Build == new Version(1, 2, 3, 5), "The offer is the verified compatible entry");
        var reports = new List<UpdateProgress>();
        string session = Session(root);
        var download = await client.DownloadAsync(offer, session, new Inline<UpdateProgress>(reports.Add));
        Check(File.ReadAllBytes(download.Installer).SequenceEqual(Payload) && download.SHA256 == Convert.ToHexStringLower(SHA256.HashData(Payload))
            && download.Installer == Path.Combine(session, UpdateFeedClient.InstallerName) && !File.Exists(Path.Combine(session, UpdateFeedClient.PartialName)),
            "The signed package reaches its owned session file unchanged");
        Check(reports[0] == new UpdateProgress(0, Payload.Length) && reports[^1] == new UpdateProgress(Payload.Length, Payload.Length), "Progress starts at zero and ends at the signed length");
        byte[] large = RandomNumberGenerator.GetBytes(10 * 64 * 1024);
        var largeOffer = offer with { Length = large.Length, Signature = key.Sign(large) };
        transport.Package = large; transport.Pause = TimeSpan.FromMilliseconds(40); reports.Clear();
        var paced = await client.DownloadAsync(largeOffer, Session(root), new Inline<UpdateProgress>(reports.Add));
        Check(File.ReadAllBytes(paced.Installer).SequenceEqual(large) && reports.Select(value => value.Received).Distinct().Count() >= 4
            && reports.Zip(reports.Skip(1)).All(pair => pair.First.Received <= pair.Second.Received) && reports.All(value => value.Total == large.Length),
            "A download without Content-Length reports growing progress toward the signed size");
        async Task Refused<T>(WindowsUpdatePackage package, string message, CancellationToken token = default) where T : Exception
        {
            string directory = Session(root);
            await Fails<T>(() => client.DownloadAsync(package, directory, null, token), message);
            Check(!Directory.EnumerateFileSystemEntries(directory).Any(), message + " (and leaves no file behind)");
        }
        transport.Pause = TimeSpan.Zero; transport.Package = null; transport.Corrupt = true;
        await Refused<InvalidDataException>(offer, "A response whose size differs from the signed offer is refused");
        transport.Corrupt = false; transport.Package = Payload.Select(value => (byte)(value ^ 1)).ToArray();
        await Refused<InvalidDataException>(offer, "A package of the right size with a bad signature never becomes setup.exe");
        transport.Package = Payload.Concat(new byte[] { 0 }).ToArray(); transport.Unsized = true;
        await Refused<InvalidDataException>(offer, "A package longer than signed stops as soon as it exceeds its size");
        transport.Package = null; transport.Unsized = false; transport.Stall = true;
        var stall = System.Diagnostics.Stopwatch.StartNew();
        await Refused<TimeoutException>(offer, "A stalled connection fails after its idle deadline");
        Check(stall.Elapsed < TimeSpan.FromSeconds(5), "The idle deadline does not wait for the overall limit");
        using (var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(50)))
            await Refused<OperationCanceledException>(offer, "Cancel stops the download as a cancellation", cancel.Token);
        transport.Stall = false; transport.Fail = true;
        await Refused<IOException>(offer, "An upstream failure is an IO failure, not a crash");
        transport.Fail = false;
        Check((await client.DownloadAsync(offer, Session(root), null)).Package == offer, "The next download recovers after a failure");
        Check(transport.Calls.All(uri => uri.Host == "127.0.0.1"), "No real feed or account was contacted");
    }
    private static async Task ServiceChecks(SigningFixture key, WindowsUpdateChannel channel, byte[] feed, string root)
    {
        var identity = new WindowsInstallationIdentity(Path.Combine(root, "service app"), channel.TestScope);
        var state = new WindowsUpdateState(Path.Combine(root, "service-state.json"));
        var clock = DateTimeOffset.UtcNow;
        var transport = new Transport(feed);
        var presenter = new Presenter();
        await using var updates = new WindowsUpdateService(action => action(), new UpdateFeedClient(channel, "x64", Current, Windows, "en", transport), state, () => clock) { Presenter = presenter };
        Check(!updates.Status.Available && !await updates.CheckAsync(), "An uninitialized updater cannot check");
        await updates.InitializeAsync(channel, identity, "en", true, () => presenter.Events.Add("quit"));
        Check(updates.Status.Available && state.Read("PacerAutomaticChecks") == "1", "Daily automatic checks default to enabled");
        Check(await updates.CheckAsync() && presenter.Events.SequenceEqual(["checking", "offer:1.2.3.5"]) && updates.Status.Busy, "A manual check shows progress, then the verified offer, and suspends island input");
        Check(!await updates.CheckAsync(), "A second check waits for the open window");
        var downloaded = await updates.DownloadAsync(null, CancellationToken.None);
        Check(string.Equals(Path.GetDirectoryName(downloaded.Directory), UpdateSessions.Root(identity.DataRoot), StringComparison.OrdinalIgnoreCase) && File.Exists(downloaded.Installer),
            "A download lands in a new session the installation owns");
        Check(!updates.Install(downloaded with { Package = downloaded.Package with { Build = new(9, 9, 9, 9) } }), "Only the offered package can be installed");
        updates.Dismiss();
        Check(!updates.Status.Busy && updates.Status.MessageKey == "updates.cancelled" && !Directory.Exists(downloaded.Directory) && updates.CurrentOffer == null,
            "Remind Me Later restores input and removes the unfinished download");
        presenter.Events.Clear();
        Check(await updates.CheckAsync(), "A new manual check works after Later"); updates.Skip();
        clock += TimeSpan.FromDays(1);
        Check(await updates.CheckAutomaticIfDueAsync() && presenter.Events.SequenceEqual(["checking", "offer:1.2.3.5"]) && !updates.Status.Busy
            && updates.Status.MessageKey == "updates.no_update", "A skipped build stays quiet in automatic checks");
        Check(await updates.CheckAsync() && presenter.Events[^1] == "offer:1.2.3.5", "A manual check still offers a skipped build");
        clock += TimeSpan.FromMinutes(31);
        transport.Feed = key.Feed(Item(key, build: "1.2.3.7"));
        await Fails<InvalidDataException>(() => updates.DownloadAsync(null, CancellationToken.None), "An offer older than its lifetime is verified again before downloading");
        Check(updates.CurrentOffer?.Build == new Version(1, 2, 3, 7), "A changed feed replaces the stale offer");
        updates.Dismiss();
        clock += TimeSpan.FromDays(1); presenter.Events.Clear();
        Check(await updates.CheckAutomaticIfDueAsync() && presenter.Events.SequenceEqual(["auto-offer:1.2.3.7"]) && updates.Status.Busy, "A newer build than the skipped one is offered automatically");
        updates.Dismiss();
        transport.Feed = key.Feed(); presenter.Events.Clear();
        Check(await updates.CheckAsync() && presenter.Events.SequenceEqual(["checking", "up-to-date"]) && updates.Status.MessageKey == "updates.no_update", "No update shows the up-to-date result");
        updates.Dismiss(); Check(!updates.Status.Busy && updates.Status.MessageKey == "updates.no_update", "Closing the result keeps its message");
        transport.Fail = true; presenter.Events.Clear();
        Check(!await updates.CheckAsync() && presenter.Events.SequenceEqual(["checking", "failed"]) && updates.Status.MessageKey == "windows.updates.failed", "A failed manual check reports it");
        updates.Dismiss();
        clock += TimeSpan.FromDays(1); presenter.Events.Clear();
        Check(!await updates.CheckAutomaticIfDueAsync() && presenter.Events.Count == 0 && !updates.Status.Busy, "A failed automatic check stays quiet");
        transport.Fail = false;
        Check(!await updates.CheckAutomaticIfDueAsync(), "A daily check is not due right after the last one");
        var failing = new PreferencesSession(new(), _ => Task.CompletedTask, _ => false);
        Check(!await updates.ApplyAutomaticAsync(false, failing) && failing.Current.AutomaticUpdates && state.Read("PacerAutomaticChecks") == "1", "A failed preference save rolls the automatic setting back");
        var saving = new PreferencesSession(new(), _ => Task.CompletedTask, _ => true);
        Check(await updates.ApplyAutomaticAsync(false, saving) && !saving.Current.AutomaticUpdates && state.Read("PacerAutomaticChecks") == "0", "Automatic checks can be disabled and persisted");
        clock += TimeSpan.FromDays(2); presenter.Events.Clear();
        Check(!await updates.CheckAutomaticIfDueAsync() && presenter.Events.Count == 0, "Disabled automatic checks never run");
        Check(await updates.CheckAsync(), "Disabling automatic checks keeps manual checks available"); updates.Dismiss();
        Check(!presenter.Events.Contains("quit"), "No check or dismissal hands off an installer");
    }
    private static async Task HttpsChecks(SigningFixture key, WindowsUpdateChannel template, string root)
    {
        await using var https = new UpdateHttpsFixture();
        var channel = template with { Feed = new Uri(https.Root, "appcast.xml"), TestCertificateSHA256 = https.CertificateSHA256 };
        https.Feed = key.Feed(Item(key, download: new Uri(https.Root, "setup.exe").AbsoluteUri)); https.Payload = Payload;
        using (var client = new UpdateFeedClient(channel, "x64", Current, Windows, "en"))
        {
            var offer = await client.ReadOfferAsync();
            Check(offer != null, "An isolated TLS certificate pin works without changing system trust: " + https.Requests + ":" + https.FailureKind + ":" + client.FailureKind);
            Check(File.ReadAllBytes((await client.DownloadAsync(offer!, Session(root), null)).Installer).SequenceEqual(Payload), "The package downloads over the pinned connection");
            https.Redirect = true; int before = https.Requests;
            await Fails<InvalidDataException>(() => client.ReadOfferAsync(), "A QA channel refuses redirects");
            Check(https.Requests == before + 1, "A redirect is never followed to another host or port");
            https.Redirect = false;
        }
        using (var wrongPin = new UpdateFeedClient(channel with { TestCertificateSHA256 = new string('0', 64) }, "x64", Current, Windows, "en"))
            await Fails<InvalidDataException>(() => wrongPin.ReadOfferAsync(), "A wrong isolated TLS pin fails closed");
        Reject(() => (channel with { Feed = new Uri("http://127.0.0.1/appcast.xml") }).Validate(), "Even local QA upstream traffic must use HTTPS");
    }
    private static async Task ProductionChecks(SigningFixture key, string root)
    {
        var production = WindowsUpdateChannel.Production; production.Validate();
        Check(production.Feed.AbsoluteUri == WindowsUpdateChannel.ReleaseFeed && production.SignerSHA256 == null && production.TestScope == null,
            "Production reads the latest GitHub Release feed and pins no Authenticode signer while installers are unsigned");
        Check(production.AllowsRedirect(new Uri("https://release-assets.githubusercontent.com/asset")) && production.AllowsRedirect(new Uri("https://github.com/asset"))
            && !production.AllowsRedirect(new Uri("https://example.com/asset")) && !production.AllowsRedirect(new Uri("http://github.com/asset"))
            && !production.AllowsRedirect(new Uri("https://github.com:8443/asset")), "Redirects stay on GitHub's HTTPS release hosts");
        Reject(() => (production with { TestScope = Guid.NewGuid(), TestCertificateSHA256 = new string('a', 64) }).Validate(), "A QA channel cannot inherit release redirects");
        var channel = production with { PublicKey = key.Public };
        const string release = "https://github.com/RyanZhangNTU/codex-pacer/releases/download/v1.2.3/", assets = "https://release-assets.githubusercontent.com/synthetic/";
        var routes = new Routes();
        routes.Redirect(WindowsUpdateChannel.ReleaseFeed, release + "appcast-windows.xml");
        routes.Redirect(release + "appcast-windows.xml", assets + "feed");
        routes.Serve(assets + "feed", key.Feed(Item(key, download: release + "setup.exe")));
        routes.Redirect(release + "setup.exe", assets + "setup");
        routes.Serve(assets + "setup", Payload);
        using (var client = new UpdateFeedClient(channel, "x64", Current, Windows, "en", routes))
        {
            var offer = (await client.ReadOfferAsync())!;
            Check(File.ReadAllBytes((await client.DownloadAsync(offer, Session(root), null)).Installer).SequenceEqual(Payload) && routes.Calls.Count == 5,
                "The release feed and installer follow GitHub's download redirects and still pass their Ed25519 checks");
        }
        foreach (string target in new[] { "https://example.com/feed", "http://release-assets.githubusercontent.com/feed" })
        {
            routes.Redirect(release + "appcast-windows.xml", target); routes.Serve(target, key.Feed(Item(key)));
            using var client = new UpdateFeedClient(channel, "x64", Current, Windows, "en", routes);
            int before = routes.Calls.Count;
            await Fails<InvalidDataException>(() => client.ReadOfferAsync(), "A redirect off GitHub's HTTPS hosts is refused");
            Check(routes.Calls.Count == before + 2, "The refused redirect target is never requested");
        }
        routes.Redirect(release + "appcast-windows.xml", WindowsUpdateChannel.ReleaseFeed);
        using (var client = new UpdateFeedClient(channel, "x64", Current, Windows, "en", routes))
        {
            int before = routes.Calls.Count;
            await Fails<InvalidDataException>(() => client.ReadOfferAsync(), "A redirect loop fails");
            Check(routes.Calls.Count - before == UpdateFeedClient.MaximumRedirects + 1, "A redirect loop stops at the hop limit");
        }
        routes.Map.Clear();
        using (var client = new UpdateFeedClient(channel, "x64", Current, Windows, "en", routes))
        {
            Check(await client.ReadOfferAsync() == null, "A release without a Windows feed reads as no update rather than an error");
            Check(await client.ReadReleaseNotesAsync() == null, "Missing release notes are absent rather than a verification failure");
        }
    }
    private static void SessionChecks(string root)
    {
        string data = Path.Combine(root, "sessions"), updates = UpdateSessions.Root(data);
        Directory.CreateDirectory(updates); File.WriteAllText(Path.Combine(updates, "state-v1.json"), "{}");
        string Make(string name, params string[] files)
        {
            string directory = Path.Combine(updates, name); Directory.CreateDirectory(directory);
            foreach (string file in files) File.WriteAllText(Path.Combine(directory, file), file);
            return directory;
        }
        string done = Make(Guid.NewGuid().ToString("N"), "setup.exe", "PacerUpdate.exe", "plan.json", "result.json", "install.log", "plan.json.0a.tmp");
        string unknown = Make(Guid.NewGuid().ToString("N"), "setup.exe", "notes.txt");
        string named = Make("not-a-session", "setup.exe");
        string locked = Make(Guid.NewGuid().ToString("N"), "setup.exe");
        string kept = Make(Guid.NewGuid().ToString("N"), "result.json");
        UpdateSessions.PreserveLog(done);
        int remaining;
        using (new FileStream(Path.Combine(locked, "setup.exe"), FileMode.Open, FileAccess.Read, FileShare.None)) remaining = UpdateSessions.Clean(data, Path.GetFileName(kept));
        Check(!Directory.Exists(done) && Directory.Exists(unknown) && Directory.Exists(named) && Directory.Exists(locked) && Directory.Exists(kept) && remaining == 3,
            "Cleanup removes finished sessions only: unknown files, other folders, locked files and the result being read stay");
        Check(File.ReadAllText(Path.Combine(updates, UpdateSessions.LastLog)) == "install.log" && File.Exists(Path.Combine(updates, "state-v1.json")),
            "The last installer log and the update state outlive their session");
        Check(UpdateSessions.Clean(data) == 1 && !Directory.Exists(locked) && !Directory.Exists(kept) && Directory.Exists(unknown),
            "A released session goes at the next attempt; a session with an unknown file never does");
    }
    private static void InstallerIdentityChecks()
    {
        var build = new Version(1, 2, 3, 45);
        foreach (Guid? scope in new Guid?[] { null, Guid.Parse("c2b87586-64b3-4f41-9614-52a6030a8153") })
        {
            var identity = new WindowsInstallationIdentity("C:/Synthetic", scope);
            string product = identity.DisplayName, description = product + " Setup", version = build.ToString();
            foreach (string suffix in new[] { "", "   ", "\0", " \0  \0 " })
            {
                UpdateHandoff.CheckInstallerIdentity(product + suffix, description, version, identity, build);
                UpdateHandoff.CheckInstallerIdentity(product, description + suffix, version, identity, build);
                UpdateHandoff.CheckInstallerIdentity(product, description, version + suffix, identity, build);
                UpdateHandoff.CheckInstallerIdentity(product + suffix, description + suffix, version + suffix, identity, build);
            }
            foreach (string changed in new[] { "Other Pacer", " " + product, "\0" + product, product.Replace("Codex", "CodeX"),
                product.Replace("Codex", "Co dex"), product.Replace("Codex", "Co\0dex"), product + "\t", product + "\u00a0", "" })
                Reject(() => UpdateHandoff.CheckInstallerIdentity(changed, description, version, identity, build),
                    "Only trailing ASCII space/NUL padding can change; product names remain exact");
            foreach (string changed in new[] { "Other Pacer Setup", " " + description, "\0" + description,
                description.Replace("Setup", "Set up"), description.Replace("Setup", "Set\0up"), description + "\t", description + "\u00a0", "" })
                Reject(() => UpdateHandoff.CheckInstallerIdentity(product, changed, version, identity, build),
                    "Descriptions must retain their exact leading and interior characters");
            Reject(() => UpdateHandoff.CheckInstallerIdentity(null, description, version, identity, build), "A missing product name is rejected");
            Reject(() => UpdateHandoff.CheckInstallerIdentity(product, null, version, identity, build), "A missing description is rejected");
            Reject(() => UpdateHandoff.CheckInstallerIdentity(product, description, null, identity, build), "A missing build is rejected");
            Reject(() => UpdateHandoff.CheckInstallerIdentity(product, description, "1.2.3.46 \0", identity, build), "Padding cannot hide a different build");
            Reject(() => UpdateHandoff.CheckInstallerIdentity(product, description, "1.2.3.4 5", identity, build), "Interior build characters are not normalized");
        }
    }
    internal static void CheckInstallerFile(string installer, string qaScope, string expectedBuild)
    {
        var identity = new WindowsInstallationIdentity("C:/Synthetic", Guid.ParseExact(qaScope, "N"));
        UpdateHandoff.CheckInstallerIdentity(installer, identity, Version.Parse(expectedBuild));
        Console.WriteLine("PASS actual installer identity and expected build; read-only, no installation or registration");
    }
    private static void SignerPolicyChecks(SigningFixture key, WindowsUpdateChannel local, string root)
    {
        var preview = new WindowsUpdateChannel(new Uri("https://updates.example.invalid/appcast.xml"), key.Public, null);
        preview.Validate();
        const string pin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        (preview with { SignerSHA256 = pin }).Validate();
        Reject(() => (preview with { SignerSHA256 = "" }).Validate(), "An explicitly invalid signer pin cannot downgrade to unsigned mode");
        Reject(() => (preview with { SignerSHA256 = new string('g', 64) }).Validate(), "A signer pin must remain a valid SHA-256 value");
        string file = Path.Combine(root, "optional-signer.exe"); File.WriteAllBytes(file, Payload);
        string digest = Convert.ToHexStringLower(SHA256.HashData(Payload)), signature = key.Sign(Payload);
        int checks = 0;
        bool Trusted(string path, string value) { checks++; Check(path == file && value == pin, "The configured signer and installer must reach the verifier unchanged"); return true; }
        UpdateHandoff.VerifyPackage(file, Payload, digest, signature, key.Public, null, (_, _) => throw new InvalidOperationException("Unsigned mode must not invoke Authenticode"));
        Check(checks == 0, "A channel without a signer pin relies on mandatory Ed25519 and SHA-256");
        UpdateHandoff.VerifyPackage(file, Payload, digest, signature, key.Public, pin, Trusted);
        Check(checks == 1, "A configured signer pin adds mandatory Authenticode validation");
        Reject(() => UpdateHandoff.VerifyPackage(file, Payload, digest, signature, key.Public, pin, (_, _) => false), "A wrong or untrusted signer must fail");
        Reject(() => UpdateHandoff.VerifyPackage(file, Payload, digest, signature, key.Public, pin), "An actual unsigned installer is rejected by a pinned channel");
        foreach (string? signer in new string?[] { null, pin })
        {
            Reject(() => UpdateHandoff.VerifyPackage(file, Payload, new string('0', 64), signature, key.Public, signer, Trusted), "A SHA-256 mismatch must fail in both signing modes");
            Reject(() => UpdateHandoff.VerifyPackage(file, Payload, digest, key.Sign([1, 2, 3]), key.Public, signer, Trusted), "A bad Ed25519 signature must fail in both signing modes");
            Reject(() => UpdateHandoff.VerifyPackage(file, Payload, digest, signature, new SigningFixture().Public, signer, Trusted), "A different Ed25519 key must fail in both signing modes");
            var channel = local with { SignerSHA256 = signer };
            var configuration = new Dictionary<string, object?>
            {
                ["schemaVersion"] = 1, ["testScope"] = local.TestScope, ["feed"] = local.Feed.AbsoluteUri,
                ["publicKey"] = key.Public, ["testCertificateSHA256"] = local.TestCertificateSHA256
            };
            if (signer != null) configuration["signerSHA256"] = signer;
            string configPath = Path.Combine(root, "signer-channel.json");
            UpdateFiles.Write(configPath, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(configuration));
            Check(WindowsUpdateChannel.ReadTest(configPath, local.TestScope!.Value).SignerSHA256 == signer,
                "Loading channel configuration must preserve an absent or configured signer pin");
            byte[] broken = key.Feed(Item(key)); broken[^5] ^= 1;
            Reject(() => UpdateCatalog.Parse(broken, channel, "x64", Current, Windows, "en"), "Feed signature checking is independent of the Authenticode policy");
            var plan = new UpdateInstallPlan(1, 1, 1, key.Public, signer, null,
                new("1.2.3", new(1, 2, 3, 5), "x64", Windows, new Uri("https://updates.example.invalid/setup.exe"), Payload.Length, signature, ""), digest);
            var restored = System.Text.Json.JsonSerializer.Deserialize<UpdateInstallPlan>(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(plan))!;
            Check(restored.SignerSHA256 == signer, "The optional signer policy survives the maintenance handoff unchanged");
            UpdateHandoff.VerifyPackage(file, Payload, restored.SHA256, restored.Package.Signature, restored.PublicKey, restored.SignerSHA256, Trusted);
        }
    }
    private static XElement WithPatch(SigningFixture key, XElement item, byte[] patch, string from, string baseDigest, string arch = "x64",
        string download = "https://127.0.0.1:9/patch.exe")
    {
        XNamespace sparkle = UpdateCatalog.Sparkle;
        item.Add(new XElement(sparkle + "deltas", new XElement("enclosure", new XAttribute("url", download), new XAttribute("length", patch.Length),
            new XAttribute("type", "application/octet-stream"), new XAttribute(sparkle + "os", "windows-" + arch), new XAttribute(sparkle + "deltaFrom", from),
            new XAttribute(sparkle + "edSignature", key.Sign(patch)), new XAttribute(UpdateCatalog.Pacer + "baseManifestSHA256", baseDigest))));
        return item;
    }
    // Patches: published inside <sparkle:deltas>, used only for the exact
    // installed manifest and build, and never again for a build whose patch
    // failed here. 4.2.2 clients keep reading the full installer.
    private static async Task DeltaChecks(SigningFixture key, WindowsUpdateChannel channel, string root)
    {
        byte[] patch = Encoding.UTF8.GetBytes("synthetic patch installer, never executed");
        var identity = new WindowsInstallationIdentity(Path.Combine(root, "delta app"), channel.TestScope);
        Directory.CreateDirectory(identity.Root);
        string manifest = Path.Combine(identity.Root, UpdateCatalog.ManifestName);
        File.WriteAllText(manifest, "{\"schemaVersion\":1,\"files\":[]}");
        string digest = UpdateCatalog.InstalledManifest(identity.Root)!;
        byte[] feed = key.Feed(WithPatch(key, Item(key), patch, Current.ToString(), digest), WithPatch(key, Item(key, "arm64", "1.2.3.6"), patch, Current.ToString(), digest, "arm64"));
        var offer = UpdateCatalog.Parse(feed, channel, "x64", Current, Windows, "en")!;
        Check(offer.Patch is { } found && found.From == Current && found.BaseManifestSHA256 == digest && found.Length == patch.Length && found.Download.AbsolutePath == "/patch.exe"
            && offer.Download.AbsolutePath == "/setup.exe" && offer.Length == Payload.Length, "The offer keeps the full installer and adds the patch for this build");
        var incremental = offer.AsIncremental();
        Check(incremental is { Incremental: true, Patch: null } && incremental.Length == patch.Length && incremental.Build == offer.Build && incremental.Notes == offer.Notes,
            "The incremental package is the same update delivered by the patch");
        Check(UpdateCatalog.Parse(feed, channel, "x64", new(1, 2, 3, 3), Windows, "en")?.Patch == null, "A patch from another build is not offered");
        Check(UpdateCatalog.Parse(key.Feed(WithPatch(key, Item(key), patch, Current.ToString(), "not-a-digest")), channel, "x64", Current, Windows, "en") is { Patch: null } full
            && full.Length == Payload.Length, "A malformed patch leaves the full installer in use");
        Check(UpdateCatalog.Parse(key.Feed(WithPatch(key, Item(key), patch, Current.ToString(), digest, download: "https://not-loopback.example/patch.exe")), channel, "x64", Current, Windows, "en")
            is { Patch: null }, "A patch outside the channel's hosts is ignored");
        var frozen = Frozen422Catalog.Parse(feed, channel, "x64", Current, Windows, "en");
        Check(frozen is { } old && old.Download.AbsolutePath == "/setup.exe" && old.Length == Payload.Length && old.Build == offer.Build,
            "The 4.2.2 parser reads the same feed and still installs the full package");

        var state = new WindowsUpdateState(Path.Combine(root, "delta-state.json"));
        var transport = new Transport(feed) { Package = patch };
        var presenter = new Presenter();
        await using var updates = new WindowsUpdateService(action => action(), new UpdateFeedClient(channel, "x64", Current, Windows, "en", transport), state) { Presenter = presenter };
        await updates.InitializeAsync(channel, identity, "en", false, () => { });
        Check(await updates.CheckAsync() && updates.CurrentOffer is { Incremental: true } planned && planned.Length == patch.Length,
            "An installation that matches the base downloads only the patch");
        var download = await updates.DownloadAsync(null, CancellationToken.None);
        Check(File.ReadAllBytes(download.Installer).SequenceEqual(patch) && download.Package == updates.CurrentOffer && transport.Calls[^1].AbsolutePath == "/patch.exe",
            "The verified patch is what the installer handoff receives");
        updates.Dismiss();
        File.AppendAllText(manifest, " ");
        transport.Package = null;
        Check(await updates.CheckAsync() && updates.CurrentOffer is { Incremental: false } fallback && fallback.Length == Payload.Length,
            "A modified installation downloads the full installer");
        updates.Dismiss();
        File.WriteAllText(manifest, "{\"schemaVersion\":1,\"files\":[]}");
        state.Write(UpdateHandoff.PatchFailedKey, offer.Build.ToString());
        Check(await updates.CheckAsync() && updates.CurrentOffer is { Incremental: false }, "After its patch failed, the same build installs in full");
        updates.Dismiss();

        string session = Guid.NewGuid().ToString("N");
        var resultState = new WindowsUpdateState(Path.Combine(root, "delta-result-state.json"));
        UpdateFiles.Write(Path.Combine(identity.DataRoot, "Updates", session, "result.json"),
            System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new UpdateInstallResult(1, false, "1.2.3.5", "", Incremental: true)));
        Check(UpdateHandoff.ConsumeResult(identity, session, resultState, Current) is { Success: false, Incremental: true }
            && resultState.Read(UpdateHandoff.PatchFailedKey) == "1.2.3.5", "A failed patch is remembered so the retry uses the full installer");
    }
    internal static async Task Serve(string directory, string qaScope, string installer, string architecture, int bytesPerSecond = 0, string? patchInstaller = null)
    {
        Guid scope = Guid.ParseExact(qaScope, "N");
        directory = WindowsInstallationIdentity.SafeRoot(directory);
        if (architecture is not ("x64" or "arm64")) throw new ArgumentException("Choose the test application's architecture.");
        var info = System.Diagnostics.FileVersionInfo.GetVersionInfo(installer);
        var build = Version.Parse(info.FileVersion ?? throw new InvalidDataException());
        UpdateHandoff.CheckInstallerIdentity(installer, new("C:/Synthetic", scope), build);
        byte[] payload = UpdateFiles.Read(installer, UpdateCatalog.PackageLimit);
        var key = new SigningFixture();
        await using var server = new UpdateHttpsFixture { Payload = payload, BytesPerSecond = bytesPerSecond };
        var item = Item(key, architecture, build.ToString(), download: new Uri(server.Root, "setup.exe").AbsoluteUri);
        item.Element("enclosure")!.SetAttributeValue("length", payload.Length);
        item.Element("enclosure")!.SetAttributeValue(UpdateCatalog.Sparkle + "edSignature", key.Sign(payload));
        item.Element(UpdateCatalog.Sparkle + "shortVersionString")!.Value = build.ToString(3);
        if (patchInstaller != null)
        {
            // The QA installation reports build 0.0.0.0 (below), so the patch is
            // published from that build, for the manifest its metadata names.
            using var patchInfo = System.Text.Json.JsonDocument.Parse(UpdateFiles.Read(Path.ChangeExtension(patchInstaller, ".json"), 64 * 1024));
            UpdateHandoff.CheckInstallerIdentity(patchInstaller, new("C:/Synthetic", scope), build);
            server.Patch = UpdateFiles.Read(patchInstaller, UpdateCatalog.PackageLimit);
            WithPatch(key, item, server.Patch, "0.0.0.0", patchInfo.RootElement.GetProperty("baseManifestSHA256").GetString()!, architecture, new Uri(server.Root, "patch.exe").AbsoluteUri);
        }
        server.Feed = key.Feed(item);
        UpdateFiles.Write(Path.Combine(directory, "channel.json"), System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, testScope = scope, feed = new Uri(server.Root, "appcast.xml").AbsoluteUri,
            publicKey = key.Public, testCertificateSHA256 = server.CertificateSHA256, testCurrentBuild = "0.0.0.0"
        }));
        Console.WriteLine("READY isolated HTTPS update feed; press Enter or close stdin to stop. Maximum lifetime: 30 minutes.");
        try { _ = await Console.In.ReadLineAsync().WaitAsync(TimeSpan.FromMinutes(30)); } catch (TimeoutException) { }
    }
    private static async Task HandoffChecks()
    {
        var events = new List<string>();
        bool result = await UpdateInstallFlow.Run(() => { events.Add("parent-exited"); return Task.CompletedTask; },
            () => { events.Add("verify"); return Task.CompletedTask; }, () => { events.Add("install"); return Task.FromResult(0); },
            ok => events.Add(ok ? "success" : "failed"), () => events.Add("relaunch"));
        Check(result && events.SequenceEqual(["parent-exited", "verify", "install", "success", "relaunch"]), "Installation follows normal shutdown, verification, result and relaunch in that order");
        events.Clear();
        result = await UpdateInstallFlow.Run(() => Task.CompletedTask, () => Task.FromException(new InvalidDataException()),
            () => { events.Add("install"); return Task.FromResult(0); }, ok => events.Add(ok ? "success" : "failed"), () => events.Add("relaunch"));
        Check(!result && events.SequenceEqual(["failed", "relaunch"]), "A bad signature never executes and relaunches the previous application");
        events.Clear();
        result = await UpdateInstallFlow.Run(() => Task.FromException(new TimeoutException()), () => Task.CompletedTask,
            () => { events.Add("install"); return Task.FromResult(0); }, ok => events.Add("failed"), () => events.Add("relaunch"));
        Check(!result && events.SequenceEqual(["failed"]), "An app that has not exited blocks installation and duplicate relaunch");
        events.Clear();
        result = await UpdateInstallFlow.Run(() => Task.CompletedTask, () => Task.CompletedTask, () => Task.FromResult(2),
            ok => events.Add(ok ? "success" : "cancelled"), () => events.Add("relaunch"));
        Check(!result && events.SequenceEqual(["cancelled", "relaunch"]), "Installer cancellation recovers the existing application");
        events.Clear();
        result = await UpdateInstallFlow.Run(() => Task.CompletedTask, () => Task.CompletedTask, () => Task.FromException<int>(new UpdateInstallerStillRunning()),
            _ => events.Add("failed"), () => events.Add("relaunch"));
        Check(!result && events.SequenceEqual(["failed"]), "An installer still replacing files is never killed or overlapped by a relaunch");
        events.Clear();
        result = await UpdateInstallFlow.Run(() => Task.CompletedTask, () => Task.CompletedTask, () => Task.FromResult(2),
            _ => throw new IOException(), () => events.Add("relaunch"));
        Check(!result && events.SequenceEqual(["relaunch"]), "A failed result write cannot prevent recovery of the application");
    }
    private static void StateChecks(string root)
    {
        string path = Path.Combine(root, "state.json"); var state = new WindowsUpdateState(path);
        state.Write("SkipThisVersion", "1.2.3.5"); Check(new WindowsUpdateState(path).Read("SkipThisVersion") == "1.2.3.5", "Update state survives restart without registry IO");
        state.Write("SkipThisVersion", null); Check(state.Read("SkipThisVersion") == null, "Configuration delete uses the same file backend");
        Check(state.ClaimNotes("1.2.3.5") && !new WindowsUpdateState(path).ClaimNotes("1.2.3.5"), "Release notes are claimed once across restarts");
        byte[] future = Encoding.UTF8.GetBytes("{\"SchemaVersion\":2,\"Values\":{}}"); File.WriteAllBytes(path, future);
        Reject(() => state.Write("SkipThisVersion", "other"), "Future configuration cannot be overwritten");
        Check(File.ReadAllBytes(path).SequenceEqual(future), "Future state bytes are preserved");
        byte[] encoded = PreferencesCodec.Encode(new DesktopPreferences { AutomaticUpdates = false });
        Check(Encoding.UTF8.GetString(encoded).Contains("SUEnableAutomaticChecks") && !PreferencesCodec.Decode(encoded).AutomaticUpdates,
            "The automatic setting uses the Mac Sparkle preference-key semantics");
        Check(PreferencesCodec.Decode(Encoding.UTF8.GetBytes("{\"schemaVersion\":2}")).AutomaticUpdates, "An absent automatic preference defaults to enabled");
        var assembly = AssemblyBuilder.DefineDynamicAssembly(new AssemblyName("PacerSyntheticVersion") { Version = new(1, 2, 3, 0) }, AssemblyBuilderAccess.Run);
        assembly.SetCustomAttribute(new CustomAttributeBuilder(typeof(AssemblyFileVersionAttribute).GetConstructor([typeof(string)])!, ["1.2.3.45"]));
        Check(WindowsUpdateVersion.Read(assembly) == new Version(1, 2, 3, 45), "Update comparisons use the packaged file build, including its revision");
        var identity = new WindowsInstallationIdentity(Path.Combine(root, "app"), Guid.NewGuid());
        string session = Guid.NewGuid().ToString("N"), resultPath = Path.Combine(identity.DataRoot, "Updates", session, "result.json");
        var notes = new UpdateInstallResult(1, true, "1.2.3.5", new string('\0', 128 * 1024));
        UpdateFiles.Write(resultPath, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(notes));
        var resultState = new WindowsUpdateState(Path.Combine(root, "notes-state.json"));
        Check(UpdateHandoff.ConsumeResult(identity, session, resultState, new(1, 2, 3, 5))?.Notes.Length == 128 * 1024,
            "Escaped metadata still accepts notes at the existing byte boundary");
        Check(UpdateHandoff.ConsumeResult(identity, session, resultState, new(1, 2, 3, 5)) == null, "A consumed successful build cannot show its notes twice");
    }
}
