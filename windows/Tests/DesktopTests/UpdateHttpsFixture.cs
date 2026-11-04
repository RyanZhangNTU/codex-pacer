using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

// Loopback TLS with an isolated certificate. PFX bytes stay in memory;
// Windows imports a temporary user key for SChannel and removes it on disposal.
// No certificate is installed in a trust store and no key is logged.
internal sealed class UpdateHttpsFixture : IAsyncDisposable
{
    private readonly RSA key = RSA.Create(2048);
    private readonly X509Certificate2 certificate;
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task accept;
    internal byte[] Feed = [];
    internal byte[] Payload = [];
    /// Served at /patch.exe, paced like the full package.
    internal byte[] Patch = [];
    internal bool Redirect;
    /// Paces the package so manual QA can watch download progress; 0 sends it at once.
    internal int BytesPerSecond;
    internal int Requests;
    internal string? FailureKind;
    internal Uri Root { get; }
    internal string CertificateSHA256 => Convert.ToHexString(SHA256.HashData(certificate.RawData));
    internal UpdateHttpsFixture()
    {
        var request = new CertificateRequest("CN=Pacer isolated update test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var names = new SubjectAlternativeNameBuilder(); names.AddIpAddress(IPAddress.Loopback);
        request.CertificateExtensions.Add(names.Build());
        using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
        byte[] pfx = generated.Export(X509ContentType.Pkcs12);
        try { certificate = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.UserKeySet); }
        finally { CryptographicOperations.ZeroMemory(pfx); }
        listener.Start(4); Root = new Uri("https://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/");
        accept = Accept();
    }
    private async Task Accept()
    {
        try { while (!lifetime.IsCancellationRequested) _ = Serve(await listener.AcceptTcpClientAsync(lifetime.Token)); }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Serve(TcpClient client)
    {
        using (client)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token))
        {
            timeout.CancelAfter(BytesPerSecond > 0 ? TimeSpan.FromMinutes(10) : TimeSpan.FromSeconds(5));
            try
            {
                await using var tls = new SslStream(client.GetStream(), false);
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, timeout.Token);
                using var reader = new StreamReader(tls, Encoding.ASCII, false, 1024, leaveOpen: true);
                int size = 0; string path = "";
                while (true)
                {
                    string? line = await reader.ReadLineAsync(timeout.Token);
                    if (line == null) return; size += line.Length; if (size > 8192) return; if (line.Length == 0) break;
                    if (line.StartsWith("GET ", StringComparison.Ordinal)) path = line.Split(' ')[1];
                }
                Interlocked.Increment(ref Requests);
                bool package = path is "/setup.exe" or "/patch.exe";
                byte[] body = Redirect ? [] : path == "/setup.exe" ? Payload : path == "/patch.exe" ? Patch : Feed;
                string header = Redirect ? "HTTP/1.1 302 Found\r\nLocation: https://127.0.0.1:9/must-not-connect?private=value\r\n"
                    : "HTTP/1.1 200 OK\r\n";
                await tls.WriteAsync(Encoding.ASCII.GetBytes(header + "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n"), timeout.Token);
                if (BytesPerSecond <= 0 || !package) await tls.WriteAsync(body, timeout.Token);
                else
                    for (int offset = 0; offset < body.Length; offset += 64 * 1024)
                    {
                        await tls.WriteAsync(body.AsMemory(offset, Math.Min(64 * 1024, body.Length - offset)), timeout.Token);
                        await Task.Delay(TimeSpan.FromSeconds(64.0 * 1024 / BytesPerSecond), timeout.Token);
                    }
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or System.Security.Authentication.AuthenticationException)
            { FailureKind = error.GetType().Name + ":" + error.HResult.ToString("X8") + ":" + (error.GetBaseException() is System.ComponentModel.Win32Exception native ? native.NativeErrorCode.ToString("X8") : "unknown"); }
        }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); listener.Stop(); await accept; certificate.Dispose(); key.Dispose(); lifetime.Dispose();
    }
}
