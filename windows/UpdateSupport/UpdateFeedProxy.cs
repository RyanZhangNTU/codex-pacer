using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

// No URL ACL, registry or system trust changes. Outbound requests are HTTPS;
// WinSparkle uses a private, token-scoped HTTP endpoint on IPv4 loopback only.
internal sealed class UpdateFeedProxy : IAsyncDisposable
{
    private sealed class Operation
    {
        internal Operation(TimeSpan idle) { Idle = idle; TokenCancellation = Lifetime.Token; }
        internal readonly string Token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        internal readonly TcpListener Listener = new(IPAddress.Loopback, 0);
        internal readonly CancellationTokenSource Lifetime = new();
        internal readonly CancellationToken TokenCancellation;
        internal readonly SemaphoreSlim Clients = new(4, 4);
        internal readonly Dictionary<string, WindowsUpdatePackage> Offers = [];
        internal readonly TimeSpan Idle;
        internal long LastRequest = Stopwatch.GetTimestamp();
        internal Task Accept = Task.CompletedTask;
        internal Uri Feed = new("http://127.0.0.1:1/inactive");
    }
    private readonly WindowsUpdateChannel channel;
    private readonly string architecture, language;
    private readonly Version current, windows;
    private readonly HttpClient http;
    private readonly TimeSpan idleLimit;
    private readonly SemaphoreSlim changes = new(1, 1);
    private readonly object sync = new();
    private Operation? operation;
    private bool disposed;
    internal event Action<Uri>? Expired;
    internal event Action<Uri>? Failed;
    internal string? FailureKind { get; private set; }
    internal bool IsListening { get { lock (sync) { return operation != null; } } }
    internal Uri Feed { get { lock (sync) { return operation?.Feed ?? new("http://127.0.0.1:1/inactive"); } } }
    internal UpdateFeedProxy(WindowsUpdateChannel channel, string architecture, Version current, Version windows, string language,
        HttpMessageHandler? transport = null, TimeSpan? idleLimit = null)
    {
        channel.Validate(); this.channel = channel; this.architecture = architecture; this.current = current; this.windows = windows; this.language = language;
        this.idleLimit = idleLimit ?? TimeSpan.FromMinutes(30);
        var handler = new HttpClientHandler { AllowAutoRedirect = false };
        if (channel.TestScope != null)
            handler.ServerCertificateCustomValidationCallback = (request, certificate, _, _) => request.RequestUri != null && channel.Allows(request.RequestUri)
                && certificate != null && string.Equals(Convert.ToHexString(SHA256.HashData(certificate.RawData)), channel.TestCertificateSHA256, StringComparison.OrdinalIgnoreCase);
        if (transport != null) handler.Dispose();
        http = new HttpClient(transport ?? handler) { Timeout = Timeout.InfiniteTimeSpan };
    }
    internal async Task<Uri> StartOperationAsync()
    {
        await changes.WaitAsync();
        try
        {
            if (disposed) throw new ObjectDisposedException(nameof(UpdateFeedProxy));
            await StopCore();
            var next = new Operation(idleLimit); next.Listener.Start(4);
            int port = ((IPEndPoint)next.Listener.LocalEndpoint).Port;
            next.Feed = new Uri($"http://127.0.0.1:{port}/{next.Token}/appcast.xml");
            lock (sync) { operation = next; }
            next.Accept = Accept(next); _ = ExpireIdle(next); return next.Feed;
        }
        finally { changes.Release(); }
    }
    internal async Task StopOperationAsync(Uri? expected = null)
    {
        await changes.WaitAsync();
        try { lock (sync) { if (expected != null && operation?.Feed != expected) return; } await StopCore(); }
        finally { changes.Release(); }
    }
    private async Task StopCore()
    {
        Operation? previous; lock (sync) { previous = operation; operation = null; }
        if (previous == null) return;
        previous.Lifetime.Cancel(); previous.Listener.Stop(); await previous.Accept;
        for (int i = 0; i < 4; i++) await previous.Clients.WaitAsync();
        previous.Clients.Dispose();
        previous.Lifetime.Dispose();
    }
    private async Task ExpireIdle(Operation value)
    {
        try
        {
            while (!value.TokenCancellation.IsCancellationRequested)
            {
                TimeSpan remaining = value.Idle - Stopwatch.GetElapsedTime(Interlocked.Read(ref value.LastRequest));
                if (remaining > TimeSpan.Zero) { await Task.Delay(remaining, value.TokenCancellation); continue; }
                await changes.WaitAsync(value.TokenCancellation);
                try
                {
                    lock (sync) { if (!ReferenceEquals(operation, value)) return; }
                    await StopCore(); Expired?.Invoke(value.Feed); return;
                }
                finally { changes.Release(); }
            }
        }
        catch (OperationCanceledException) { }
    }
    private async Task Accept(Operation value)
    {
        try
        {
            while (!value.TokenCancellation.IsCancellationRequested)
            {
                var client = await value.Listener.AcceptTcpClientAsync(value.TokenCancellation);
                bool acquired;
                try { acquired = await value.Clients.WaitAsync(0, value.TokenCancellation); }
                catch { client.Dispose(); throw; }
                if (!acquired) { client.Dispose(); continue; }
                _ = Serve(value, client);
            }
        }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Serve(Operation value, TcpClient client)
    {
        using (client)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(value.TokenCancellation))
        {
            timeout.CancelAfter(TimeSpan.FromMinutes(5)); using var stream = client.GetStream();
            try
            {
                using var headerTimeout = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
                headerTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                var request = new List<byte>(); byte[] one = new byte[1];
                while (request.Count < 8192)
                {
                    if (await stream.ReadAsync(one, headerTimeout.Token) == 0) return;
                    request.Add(one[0]);
                    if (request.Count >= 4 && request.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                }
                if (request.Count >= 8192) return;
                string[] parts = Encoding.ASCII.GetString(request.ToArray()).Split("\r\n", 2)[0].Split(' ');
                string prefix = "/" + value.Token + "/";
                if (parts.Length != 3 || parts[0] != "GET" || !parts[1].StartsWith(prefix, StringComparison.Ordinal))
                { await Reply(stream, 404, [], timeout.Token); return; }
                byte[] payload; string type;
                if (parts[1] == value.Feed.AbsolutePath)
                {
                    Interlocked.Exchange(ref value.LastRequest, Stopwatch.GetTimestamp());
                    using var feedTimeout = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
                    feedTimeout.CancelAfter(TimeSpan.FromSeconds(20));
                    byte[]? signed = await Fetch(channel.Feed, UpdateCatalog.FeedLimit, feedTimeout.Token, missingIsEmpty: true);
                    var item = signed == null ? null : UpdateCatalog.Parse(signed, channel, architecture, current, windows, language);
                    string? token = null;
                    if (item != null)
                    {
                        lock (sync)
                        {
                            token = value.Offers.FirstOrDefault(pair => pair.Value == item).Key;
                            if (token == null)
                            {
                                token = Guid.NewGuid().ToString("N");
                                if (value.Offers.Count >= 4) value.Offers.Remove(value.Offers.Keys.First());
                                value.Offers[token] = item;
                            }
                        }
                    }
                    payload = UpdateCatalog.Project(item, token == null ? null : new Uri(value.Feed, token + "/setup.exe")); type = "application/rss+xml";
                }
                else
                {
                    string? token = parts[1].Length >= prefix.Length + 10 && parts[1].EndsWith("/setup.exe", StringComparison.Ordinal) ? parts[1][prefix.Length..^10] : null;
                    WindowsUpdatePackage? item; lock (sync) { item = token == null ? null : value.Offers.GetValueOrDefault(token); }
                    if (item == null) { await Reply(stream, 404, [], timeout.Token); return; }
                    Interlocked.Exchange(ref value.LastRequest, Stopwatch.GetTimestamp());
                    payload = (await Fetch(item.Download, UpdateCatalog.PackageLimit, timeout.Token))!;
                    if (payload.LongLength != item.Length || !UpdateCatalog.Verify(payload, item.Signature, channel.PublicKey))
                        throw new InvalidDataException("The update package signature is invalid.");
                    type = "application/octet-stream";
                }
                await Reply(stream, 200, payload, timeout.Token, type);
            }
            catch (Exception error) when (error is IOException or InvalidDataException or HttpRequestException or OperationCanceledException or FormatException or System.Xml.XmlException or ArgumentException or UnauthorizedAccessException)
            {
                FailureKind = error.GetType().Name + ":" + error.HResult.ToString("X8", System.Globalization.CultureInfo.InvariantCulture);
                try { await Reply(stream, 502, Encoding.ASCII.GetBytes("Update verification or download failed."), timeout.Token); }
                catch (Exception failure) when (failure is IOException or OperationCanceledException or ObjectDisposedException or InvalidOperationException) { }
                _ = FailOperation(value);
            }
            finally { value.Clients.Release(); }
        }
    }
    private async Task FailOperation(Operation value)
    {
        await changes.WaitAsync();
        try
        {
            lock (sync) { if (!ReferenceEquals(operation, value)) return; }
            await StopCore(); Failed?.Invoke(value.Feed);
        }
        finally { changes.Release(); }
    }
    internal async Task<string?> ReadReleaseNotesAsync(CancellationToken cancellation = default)
    {
        if (disposed) throw new ObjectDisposedException(nameof(UpdateFeedProxy));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            var feed = await Fetch(channel.Feed, UpdateCatalog.FeedLimit, timeout.Token, missingIsEmpty: true);
            return feed == null ? null : UpdateCatalog.Parse(feed, channel, architecture, current, windows, language, notesForCurrentBuild: true)?.Notes;
        }
        catch (Exception error) when (error is HttpRequestException or FormatException or System.Xml.XmlException)
        { throw new InvalidDataException("Signed release notes could not be verified."); }
    }
    internal const int MaximumRedirects = 4;
    // Release assets redirect from github.com to GitHub's download hosts. Each hop must stay
    // HTTPS on a channel-listed host; a missing feed means no release for Windows yet.
    private async Task<byte[]?> Fetch(Uri url, int limit, CancellationToken cancellation, bool missingIsEmpty = false)
    {
        Uri target = url;
        for (int hop = 0; ; hop++)
        {
            if (!channel.Allows(target)) throw new InvalidDataException("The update URL is not allowed.");
            using var response = await http.GetAsync(target, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                Uri? location = response.Headers.Location;
                if (hop >= MaximumRedirects || location == null) throw new InvalidDataException("Invalid update redirect.");
                Uri next = location.IsAbsoluteUri ? location : new Uri(target, location);
                if (!channel.AllowsRedirect(next)) throw new InvalidDataException("The update redirect is not allowed.");
                target = next; continue;
            }
            if (missingIsEmpty && response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            if (response.RequestMessage?.RequestUri != target || response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Invalid update response.");
            await using var input = await response.Content.ReadAsStreamAsync(cancellation);
            using var result = new MemoryStream(); byte[] buffer = new byte[64 * 1024]; int count;
            while ((count = await input.ReadAsync(buffer, cancellation)) > 0)
            { if (result.Length + count > limit) throw new InvalidDataException("Update data exceeds its limit."); result.Write(buffer, 0, count); }
            return result.ToArray();
        }
    }
    internal WindowsUpdatePackage ValidateDownloaded(byte[] bytes)
    {
        WindowsUpdatePackage[] candidates; lock (sync) { candidates = operation?.Offers.Values.ToArray() ?? []; }
        return candidates.FirstOrDefault(item => bytes.LongLength == item.Length && UpdateCatalog.Verify(bytes, item.Signature, channel.PublicKey))
            ?? throw new InvalidDataException("The downloaded installer does not match a verified offer.");
    }
    private static async Task Reply(Stream stream, int code, byte[] body, CancellationToken token, string type = "text/plain")
    {
        byte[] header = Encoding.ASCII.GetBytes($"HTTP/1.1 {code} {(code == 200 ? "OK" : "Unavailable")}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, token); if (body.Length != 0) await stream.WriteAsync(body, token);
    }
    public async ValueTask DisposeAsync()
    {
        await changes.WaitAsync();
        try { if (disposed) return; disposed = true; await StopCore(); http.Dispose(); }
        finally { changes.Release(); }
    }
}
