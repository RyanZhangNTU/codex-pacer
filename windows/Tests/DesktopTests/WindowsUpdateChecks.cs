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
    private sealed class Transport(byte[] feed) : HttpMessageHandler
    {
        internal byte[] Feed = feed;
        internal bool Fail, Corrupt;
        internal readonly List<Uri> Calls = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls.Add(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(Fail ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK)
            {
                RequestMessage = request,
                Content = new ByteArrayContent(request.RequestUri!.AbsolutePath.EndsWith(".xml", StringComparison.Ordinal) ? Feed : Corrupt ? [1, 2, 3] : Payload)
            });
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
    private sealed class Backend : IWindowsUpdateBackend
    {
        public event Action<UpdateBackendEvent, long>? Changed;
        public Func<string, bool>? Install { get; set; }
        internal bool Automatic, Block, FailSet;
        internal int Checks, Disposals;
        internal Uri? LastFeed;
        internal long Context;
        internal bool Interactive;
        internal readonly ManualResetEventSlim Held = new(false);
        public void Initialize(Uri feed, string key, string version, string build, string language, bool automatic) { Automatic = automatic; }
        public void Check(Uri feed, bool interactive, long context) { Context = context; LastFeed = feed; Interactive = interactive; Checks++; if (Block) Held.Wait(); }
        public void SetAutomatic(bool value) { if (FailSet) throw new IOException(); Automatic = value; }
        internal void Emit(UpdateBackendEvent value, long? context = null) => Changed?.Invoke(value, context ?? Context);
        public void Dispose() { Disposals++; Held.Set(); }
    }
    internal static async Task Run(string? nativeDirectory = null)
    {
        InstallerIdentityChecks();
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
            await using (var notes = new UpdateFeedProxy(channel, "x64", new(1, 2, 3, 5), Windows, "zh-Hans", notesTransport))
            {
                Check(await notes.ReadReleaseNotesAsync() == "合成中文说明" && !notes.IsListening && notesTransport.Calls.Count == 1,
                    "An explicit release-notes read verifies the current build and language without starting a proxy or fetching a package");
                notesTransport.Feed = feed.ToArray(); notesTransport.Feed[^1] ^= 1;
                bool rejected = false;
                try { _ = await notes.ReadReleaseNotesAsync(); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "Manual release notes reject a modified feed instead of reusing cached text");
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
            var transport = new Transport(feed);
            await using (var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "zh-Hans", transport))
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) })
            {
                Check(!proxy.IsListening, "Construction must not open a listener");
                await proxy.StartOperationAsync();
                byte[] projected = await http.GetByteArrayAsync(proxy.Feed);
                string text = Encoding.UTF8.GetString(projected);
                Check(text.Contains("合成中文说明") && !text.Contains("never-fetch") && !text.Contains("windows-arm64"), "The local feed exposes only verified compatible notes and no remote note URL");
                var enclosure = XDocument.Parse(text).Descendants("enclosure").Single();
                var url = new Uri(enclosure.Attribute("url")!.Value);
                Check(url.Host == "127.0.0.1" && url.Port == proxy.Feed.Port, "The download is restricted to the bounded loopback proxy");
                Check((await http.GetByteArrayAsync(url)).SequenceEqual(Payload), "The signed package reaches the SDK unchanged");
                Check(proxy.ValidateDownloaded(Payload).Build == item!.Build, "The installer callback must match a verified offer");
                Reject(() => proxy.ValidateDownloaded([1, 2, 3]), "A replaced downloaded installer cannot reach the handoff");
                transport.Corrupt = true;
                using (var invalid = await http.GetAsync(url)) Check(!invalid.IsSuccessStatusCode, "A bad package signature is not served");
                await Closed(proxy);
                Uri oldFeed = proxy.Feed;
                transport.Corrupt = false; transport.Fail = true;
                await proxy.StartOperationAsync();
                using (var unavailable = await http.GetAsync(proxy.Feed)) Check(!unavailable.IsSuccessStatusCode, "A failed download remains an error");
                await Closed(proxy);
                transport.Fail = false; await proxy.StartOperationAsync();
                Check((await http.GetAsync(proxy.Feed)).IsSuccessStatusCode, "The next check recovers after a download failure");
                using var forbidden = await http.GetAsync(new Uri(proxy.Feed, "/not-owned"));
                Check(forbidden.StatusCode == HttpStatusCode.NotFound, "The proxy has no unscoped endpoints");
                Check(transport.Calls.All(uri => uri.Host == "127.0.0.1"), "No real feed or account was contacted");
            }
            await ServiceChecks(channel, feed);
            await LifetimeChecks(channel, feed, root);
            await HttpsChecks(key, channel);
            await ProductionChecks(key);
            await HandoffChecks();
            SignerPolicyChecks(key, channel, root);
            StateChecks(root);
            string unsigned = Path.Combine(root, "unsigned.exe"); File.WriteAllBytes(unsigned, Payload);
            Check(!UpdateAuthenticode.Verify(unsigned, new string('0', 64)), "Production rejects unsigned installers without installing test trust");
            if (nativeDirectory != null)
            {
                using var native = new WinSparkleNative(nativeDirectory, new WindowsUpdateState(Path.Combine(root, "native-state.json")));
                Check(native.ValidateKey(key.Public), "The pinned native x64/ARM64 DLL accepts the isolated test public key");
                Check(!native.ValidateKey("invalid"), "The pinned native DLL rejects invalid keys without starting update UI");
            }
            Console.WriteLine("PASS Windows updates: isolated signed feed/package, architecture/OS filtering, private loopback, async deadlines, rollback, shutdown ordering, recovery and once-only notes");
        }
        finally { Directory.Delete(root, recursive: true); }
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
    internal static async Task Serve(string directory, string qaScope, string installer, string architecture)
    {
        Guid scope = Guid.ParseExact(qaScope, "N");
        directory = WindowsInstallationIdentity.SafeRoot(directory);
        if (architecture is not ("x64" or "arm64")) throw new ArgumentException("Choose the test application's architecture.");
        var info = System.Diagnostics.FileVersionInfo.GetVersionInfo(installer);
        var build = Version.Parse(info.FileVersion ?? throw new InvalidDataException());
        UpdateHandoff.CheckInstallerIdentity(installer, new("C:/Synthetic", scope), build);
        byte[] payload = UpdateFiles.Read(installer, UpdateCatalog.PackageLimit);
        var key = new SigningFixture();
        await using var server = new UpdateHttpsFixture { Payload = payload };
        var item = Item(key, architecture, build.ToString(), download: new Uri(server.Root, "setup.exe").AbsoluteUri);
        item.Element("enclosure")!.SetAttributeValue("length", payload.Length);
        item.Element("enclosure")!.SetAttributeValue(UpdateCatalog.Sparkle + "edSignature", key.Sign(payload));
        item.Element(UpdateCatalog.Sparkle + "shortVersionString")!.Value = build.ToString(3);
        server.Feed = key.Feed(item);
        UpdateFiles.Write(Path.Combine(directory, "channel.json"), System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new
        {
            schemaVersion = 1, testScope = scope, feed = new Uri(server.Root, "appcast.xml").AbsoluteUri,
            publicKey = key.Public, testCertificateSHA256 = server.CertificateSHA256, testCurrentBuild = "0.0.0.0"
        }));
        Console.WriteLine("READY isolated HTTPS update feed; press Enter or close stdin to stop. Maximum lifetime: 30 minutes.");
        try { _ = await Console.In.ReadLineAsync().WaitAsync(TimeSpan.FromMinutes(30)); } catch (TimeoutException) { }
    }
    private static async Task Closed(UpdateFeedProxy proxy)
    {
        for (int i=0;i<100 && proxy.IsListening;i++) await Task.Delay(10);
        Check(!proxy.IsListening, "The operation must close its listener on failure or completion");
        await proxy.StopOperationAsync();
    }
    private static async Task LifetimeChecks(WindowsUpdateChannel channel, byte[] feed, string root)
    {
        var backend = new Backend();
        await using var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", new Transport(feed), TimeSpan.FromMilliseconds(100));
        await using var updates = new WindowsUpdateService(action => action(), backend, proxy);
        await updates.InitializeAsync(channel, "1.2.3", Current.ToString(), "en", false, new("C:/Synthetic", channel.TestScope), () => { });
        Check(!proxy.IsListening, "An initialized updater has no listening socket before a check");
        Check(await updates.CheckAsync(), "A manual update operation starts");
        long firstContext = backend.Context;
        Uri first = backend.LastFeed!;
        Check(first.Host == "127.0.0.1" && first.Port != 0, "The operation binds an ephemeral IPv4 loopback port");
        backend.Emit(UpdateBackendEvent.Found);
        await Closed(proxy);
        Check(updates.Status.MessageKey == "windows.updates.expired", "Thirty idle minutes end the operation through the injected idle deadline");
        backend.Emit(UpdateBackendEvent.Failed); // Download selected in the expired native window.
        for (int i = 0; i < 100 && backend.Checks < 2; i++) await Task.Delay(10);
        Check(backend.Checks == 2 && backend.LastFeed!.AbsolutePath != first.AbsolutePath, "Expired Download restarts with a fresh operation token");
        backend.Emit(UpdateBackendEvent.NoUpdate, firstContext);
        Check(proxy.IsListening, "A late completion from the previous operation cannot close the new proxy");
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        using var stale = await http.GetAsync(new Uri(backend.LastFeed!, first.AbsolutePath));
        Check(stale.StatusCode == HttpStatusCode.NotFound, "A previous operation's token cannot access the new listener");
        backend.Emit(UpdateBackendEvent.NoUpdate); await Closed(proxy);
        backend.Emit(UpdateBackendEvent.Dismissed); Check(!updates.Status.Busy, "Closing the native window restores interaction");
        Check(await updates.CheckAsync(), "A new manual check works after dismissal");
        backend.Emit(UpdateBackendEvent.Dismissed); await Closed(proxy);
        Check(!backend.Install!(Path.Combine(root, "not-an-installer")), "A completed operation cannot start an installer");
        var state = new WindowsUpdateState(Path.Combine(root, "daily.json"));
        var clock = DateTimeOffset.UtcNow;
        state.Write("PacerLastCheckUtc", clock.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture));
        var autoBackend = new Backend();
        await using var autoProxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", new Transport(feed));
        await using var automatic = new WindowsUpdateService(action => action(), autoBackend, autoProxy, state: state, now: () => clock);
        await automatic.InitializeAsync(channel, "1.2.3", Current.ToString(), "en", true, new("C:/Synthetic", channel.TestScope), () => { });
        Check(!await automatic.CheckAutomaticIfDueAsync() && !autoProxy.IsListening, "A daily check is not due immediately after a saved check");
        clock += TimeSpan.FromDays(1);
        Check(await automatic.CheckAutomaticIfDueAsync() && !autoBackend.Interactive, "Daily automatic checks run without a manual progress window");
        autoBackend.Emit(UpdateBackendEvent.NoUpdate); await Closed(autoProxy);
        Check(await automatic.SetAutomaticAsync(false), "Automatic scheduling can be disabled"); clock += TimeSpan.FromDays(2);
        Check(!await automatic.CheckAutomaticIfDueAsync() && !autoProxy.IsListening, "Disabled automatic checks keep their listener closed");
    }
    private static async Task HttpsChecks(SigningFixture key, WindowsUpdateChannel template)
    {
        await using var https = new UpdateHttpsFixture();
        var channel = template with { Feed = new Uri(https.Root, "appcast.xml"), TestCertificateSHA256 = https.CertificateSHA256 };
        https.Feed = key.Feed(Item(key, download: new Uri(https.Root, "setup.exe").AbsoluteUri));
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        await using var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en");
        await proxy.StartOperationAsync();
        using (var valid = await http.GetAsync(proxy.Feed)) Check(valid.IsSuccessStatusCode, "An isolated TLS certificate pin works without changing system trust: " + https.Requests + ":" + https.FailureKind + ":" + proxy.FailureKind);
        await proxy.StopOperationAsync(); https.Redirect = true;
        int before = https.Requests; await proxy.StartOperationAsync();
        using (var redirect = await http.GetAsync(proxy.Feed))
            Check(redirect.StatusCode == HttpStatusCode.BadGateway && (await redirect.Content.ReadAsStringAsync()) == "Update verification or download failed.", "Redirects receive a fixed error response without URL parameters");
        await Closed(proxy); Check(https.Requests == before + 1, "A redirect is never followed to another host or port");
        https.Redirect = false;
        await using var wrongPin = new UpdateFeedProxy(channel with { TestCertificateSHA256 = new string('0', 64) }, "x64", Current, Windows, "en");
        await wrongPin.StartOperationAsync();
        using (var invalid = await http.GetAsync(wrongPin.Feed)) Check(invalid.StatusCode == HttpStatusCode.BadGateway, "A wrong isolated TLS pin fails closed");
        await Closed(wrongPin);
        Reject(() => (channel with { Feed = new Uri("http://127.0.0.1/appcast.xml") }).Validate(), "Even local QA upstream traffic must use HTTPS");
    }
    private static async Task ProductionChecks(SigningFixture key)
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
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        await using (var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", routes))
        {
            await proxy.StartOperationAsync();
            var url = new Uri(XDocument.Parse(await http.GetStringAsync(proxy.Feed)).Descendants("enclosure").Single().Attribute("url")!.Value);
            Check((await http.GetByteArrayAsync(url)).SequenceEqual(Payload) && routes.Calls.Count == 5,
                "The release feed and installer follow GitHub's download redirects and still pass their Ed25519 checks");
            await proxy.StopOperationAsync();
        }
        foreach (string target in new[] { "https://example.com/feed", "http://release-assets.githubusercontent.com/feed" })
        {
            routes.Redirect(release + "appcast-windows.xml", target); routes.Serve(target, key.Feed(Item(key)));
            await using var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", routes);
            await proxy.StartOperationAsync(); int before = routes.Calls.Count;
            using (var refused = await http.GetAsync(proxy.Feed))
                Check(refused.StatusCode == HttpStatusCode.BadGateway && routes.Calls.Count == before + 2, "A redirect off GitHub's HTTPS hosts is refused before it is requested");
            await Closed(proxy);
        }
        routes.Redirect(release + "appcast-windows.xml", WindowsUpdateChannel.ReleaseFeed);
        await using (var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", routes))
        {
            await proxy.StartOperationAsync(); int before = routes.Calls.Count;
            using (var loop = await http.GetAsync(proxy.Feed))
                Check(loop.StatusCode == HttpStatusCode.BadGateway && routes.Calls.Count - before == UpdateFeedProxy.MaximumRedirects + 1, "A redirect loop stops at the hop limit");
            await Closed(proxy);
        }
        routes.Map.Clear();
        await using (var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", routes))
        {
            await proxy.StartOperationAsync();
            Check(!XDocument.Parse(await http.GetStringAsync(proxy.Feed)).Descendants("item").Any(), "A release without a Windows feed reads as no update rather than an error");
            Check(await proxy.ReadReleaseNotesAsync() == null, "Missing release notes are absent rather than a verification failure");
            await proxy.StopOperationAsync();
        }
    }
    private static async Task ServiceChecks(WindowsUpdateChannel channel, byte[] feed)
    {
        var backend = new Backend();
        await using var proxy = new UpdateFeedProxy(channel, "x64", Current, Windows, "en", new Transport(feed));
        await using (var updates = new WindowsUpdateService(action => action(), backend, proxy, TimeSpan.FromMilliseconds(100)))
        {
            await updates.InitializeAsync(channel, "1.2.3", Current.ToString(), "en", true, new("C:/Synthetic", channel.TestScope), () => throw new InvalidOperationException());
            Check(backend.Automatic && updates.Status.Available, "Daily automatic checks default to enabled");
            var preferences = new PreferencesSession(new(), _ => Task.CompletedTask, _ => false);
            Check(!await updates.ApplyAutomaticAsync(false, preferences) && backend.Automatic && preferences.Current.AutomaticUpdates, "A failed preference save rolls the native setting back");
            preferences = new PreferencesSession(new(), _ => Task.CompletedTask, _ => true);
            Check(await updates.ApplyAutomaticAsync(false, preferences) && !backend.Automatic && !preferences.Current.AutomaticUpdates, "Automatic checks can be disabled and persisted");
            Check(await updates.CheckAsync() && backend.Checks == 1, "Disabling automatic checks keeps manual checks available");
            backend.Emit(UpdateBackendEvent.NoUpdate); Check(updates.Status.MessageKey == "updates.no_update", "No-update result reaches the host");
            backend.Emit(UpdateBackendEvent.Dismissed); Check(!updates.Status.Busy, "Dismissal restores island input");
            Check(await updates.CheckAsync(), "A later background-style result belongs to a fresh active operation");
            backend.Emit(UpdateBackendEvent.Found); Check(updates.Status.Busy, "Background update UI suspends island input");
            backend.Emit(UpdateBackendEvent.Dismissed);
            backend.FailSet = true; Check(!await updates.ApplyAutomaticAsync(true, preferences) && !preferences.Current.AutomaticUpdates, "A native switch failure preserves the previous preference");
            backend.FailSet = false; backend.Block = true;
            var timer = System.Diagnostics.Stopwatch.StartNew(); Task<bool> slow = updates.CheckAsync();
            Check(!slow.IsCompleted && !backend.Held.IsSet, "An unresponsive native updater must yield while its worker is still blocked");
            Check(!await slow && timer.Elapsed < TimeSpan.FromSeconds(1) && !updates.Status.Busy, "The request deadline restores interaction without a busy wait");
            backend.Emit(UpdateBackendEvent.Found); Check(!updates.Status.Available, "A late callback cannot revive a timed-out updater");
            backend.Held.Set();
        }
        Check(backend.Disposals == 1, "Native cleanup runs once");
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
        state.Write("SkipThisVersion", "1.2.3.5"); Check(new WindowsUpdateState(path).Read("SkipThisVersion") == "1.2.3.5", "WinSparkle configuration survives restart without registry IO");
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
