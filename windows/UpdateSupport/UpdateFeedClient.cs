using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal readonly record struct UpdateProgress(long Received, long Total);
internal sealed record VerifiedDownload(string Directory, string Installer, WindowsUpdatePackage Package, string SHA256);

// No listener, URL ACL, registry or system trust changes. Requests are HTTPS
// only; a package is written to the caller's owned session directory and is
// verified before anything can run it.
internal sealed class UpdateFeedClient : IDisposable
{
    internal const int MaximumRedirects = 4;
    internal const string PartialName = "setup.exe.download", InstallerName = "setup.exe";
    private readonly WindowsUpdateChannel channel;
    private readonly string architecture, language;
    private readonly Version current, windows;
    private readonly HttpClient http;
    private readonly TimeSpan stall;
    private bool disposed;
    internal string? FailureKind { get; private set; }
    internal UpdateFeedClient(WindowsUpdateChannel channel, string architecture, Version current, Version windows, string language,
        HttpMessageHandler? transport = null, TimeSpan? stall = null)
    {
        channel.Validate(); this.channel = channel; this.architecture = architecture; this.current = current; this.windows = windows; this.language = language;
        this.stall = stall ?? TimeSpan.FromSeconds(60);
        var handler = new HttpClientHandler { AllowAutoRedirect = false };
        if (channel.TestScope != null)
            handler.ServerCertificateCustomValidationCallback = (request, certificate, _, _) => request.RequestUri != null && channel.Allows(request.RequestUri)
                && certificate != null && string.Equals(Convert.ToHexString(SHA256.HashData(certificate.RawData)), channel.TestCertificateSHA256, StringComparison.OrdinalIgnoreCase);
        if (transport != null) handler.Dispose();
        http = new HttpClient(transport ?? handler) { Timeout = Timeout.InfiniteTimeSpan };
    }
    /// The newest signed, compatible package above the running build, if any.
    internal Task<WindowsUpdatePackage?> ReadOfferAsync(CancellationToken cancellation = default) => ReadFeedAsync(notesForCurrentBuild: false, cancellation);
    internal async Task<string?> ReadReleaseNotesAsync(CancellationToken cancellation = default) => (await ReadFeedAsync(notesForCurrentBuild: true, cancellation))?.Notes;
    private async Task<WindowsUpdatePackage?> ReadFeedAsync(bool notesForCurrentBuild, CancellationToken cancellation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            var feed = await Fetch(channel.Feed, UpdateCatalog.FeedLimit, timeout.Token, missingIsEmpty: true);
            return feed == null ? null : UpdateCatalog.Parse(feed, channel, architecture, current, windows, language, notesForCurrentBuild);
        }
        catch (Exception error) when (error is HttpRequestException or FormatException or System.Xml.XmlException)
        { Fail(error); throw new InvalidDataException("The signed update feed could not be verified.", error); }
        catch (Exception error) when (error is IOException or InvalidDataException or OperationCanceledException) { Fail(error); throw; }
    }
    /// Streams the package into directory\setup.exe.download, then checks its
    /// length and Ed25519 signature before naming it setup.exe. Any failure
    /// leaves neither file behind.
    internal async Task<VerifiedDownload> DownloadAsync(WindowsUpdatePackage item, string directory, IProgress<UpdateProgress>? progress,
        CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        string partial = Path.Combine(directory, PartialName), installer = Path.Combine(directory, InstallerName);
        UpdateFiles.Check(directory);
        using var overall = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        overall.CancelAfter(TimeSpan.FromMinutes(60));
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(overall.Token);
        try
        {
            idle.CancelAfter(stall);
            using (var response = await Open(item.Download, idle.Token, missingIsEmpty: false))
            {
                if (response!.Content.Headers.ContentLength is long announced && announced != item.Length)
                    throw new InvalidDataException("The update size differs from the signed offer.");
                await using var input = await response.Content.ReadAsStreamAsync(idle.Token);
                await using var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024);
                byte[] buffer = new byte[64 * 1024]; long received = 0; var clock = Stopwatch.StartNew(); TimeSpan reported = TimeSpan.Zero;
                progress?.Report(new(0, item.Length));
                while (true)
                {
                    // A stalled connection fails after its own deadline, however long the whole download takes.
                    idle.CancelAfter(stall);
                    int count = await input.ReadAsync(buffer, idle.Token);
                    if (count == 0) break;
                    if (received + count > item.Length) throw new InvalidDataException("The update exceeds its signed size.");
                    await output.WriteAsync(buffer.AsMemory(0, count), idle.Token); received += count;
                    if (clock.Elapsed - reported >= TimeSpan.FromMilliseconds(100)) { reported = clock.Elapsed; progress?.Report(new(received, item.Length)); }
                }
                if (received != item.Length) throw new InvalidDataException("The update download is incomplete.");
                await output.FlushAsync(idle.Token); output.Flush(true);
                progress?.Report(new(received, item.Length));
            }
            byte[] bytes = UpdateFiles.Read(partial, UpdateCatalog.PackageLimit);
            if (bytes.LongLength != item.Length || !UpdateCatalog.Verify(bytes, item.Signature, channel.PublicKey))
                throw new InvalidDataException("The update package signature is invalid.");
            string digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
            UpdateFiles.Check(installer); File.Move(partial, installer, overwrite: false);
            return new(directory, installer, item, digest);
        }
        catch (Exception error)
        {
            Fail(error);
            try { File.Delete(partial); } catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            if (error is HttpRequestException) throw new IOException("The update download failed.", error);
            // A caller's cancellation stays a cancellation; a stall or the overall limit is a failure.
            if (error is OperationCanceledException && !cancellation.IsCancellationRequested) throw new TimeoutException("The update download stopped responding.", error);
            throw;
        }
    }
    private void Fail(Exception error) => FailureKind = error.GetType().Name + ":" + error.HResult.ToString("X8", System.Globalization.CultureInfo.InvariantCulture);
    // Release assets redirect from github.com to GitHub's download hosts. Each hop must stay
    // HTTPS on a channel-listed host; a missing feed means no release for Windows yet.
    private async Task<HttpResponseMessage?> Open(Uri url, CancellationToken cancellation, bool missingIsEmpty)
    {
        Uri target = url;
        for (int hop = 0; ; hop++)
        {
            if (!channel.Allows(target)) throw new InvalidDataException("The update URL is not allowed.");
            var response = await http.GetAsync(target, HttpCompletionOption.ResponseHeadersRead, cancellation);
            try
            {
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    Uri? location = response.Headers.Location;
                    if (hop >= MaximumRedirects || location == null) throw new InvalidDataException("Invalid update redirect.");
                    Uri next = location.IsAbsoluteUri ? location : new Uri(target, location);
                    if (!channel.AllowsRedirect(next)) throw new InvalidDataException("The update redirect is not allowed.");
                    target = next; response.Dispose(); continue;
                }
                if (missingIsEmpty && response.StatusCode == HttpStatusCode.NotFound) { response.Dispose(); return null; }
                response.EnsureSuccessStatusCode();
                if (response.RequestMessage?.RequestUri != target) throw new InvalidDataException("Invalid update response.");
                return response;
            }
            catch { response.Dispose(); throw; }
        }
    }
    private async Task<byte[]?> Fetch(Uri url, int limit, CancellationToken cancellation, bool missingIsEmpty = false)
    {
        using var response = await Open(url, cancellation, missingIsEmpty);
        if (response == null) return null;
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Invalid update response.");
        await using var input = await response.Content.ReadAsStreamAsync(cancellation);
        using var result = new MemoryStream(); byte[] buffer = new byte[64 * 1024]; int count;
        while ((count = await input.ReadAsync(buffer, cancellation)) > 0)
        { if (result.Length + count > limit) throw new InvalidDataException("Update data exceeds its limit."); result.Write(buffer, 0, count); }
        return result.ToArray();
    }
    public void Dispose() { if (disposed) return; disposed = true; http.Dispose(); }
}
