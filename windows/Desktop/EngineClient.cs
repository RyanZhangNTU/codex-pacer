using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed class EngineClient : IAsyncDisposable
{
    private const int Version = 1, MaximumFrame = 1024 * 1024;
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim writing = new(1, 1);
    private SynchronizationContext? callbacks;
    private void Publish(Action action)
    {
        if (callbacks is { } context && context != SynchronizationContext.Current) context.Post(_ => action(), null);
        else action();
    }
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement?>> pending = new();
    private readonly TimeSpan commandTimeout;
    private Process? process;
    private OwnedJob? job;
    private Task? reading, drainingErrors;
    private long request;
    private ulong sequence;
    private volatile bool initialized;
    private volatile bool disposing;
    private volatile bool connectionClosed;
    private volatile bool acceptsWebHostMessages;
    private volatile bool acceptsClaudeHostMessages;
    private EngineSnapshot? latestSnapshot;
    internal EngineSnapshot? LatestSnapshot => Volatile.Read(ref latestSnapshot);
    internal bool IsInitialized => initialized;
    internal int? ProcessId => process?.Id;
    internal bool IsConnectionClosed => disposing || connectionClosed;
    internal event Action<EngineSnapshot>? Snapshot;
    internal event Action<string>? Status;
    internal event Action<EngineHostRequest>? HostRequest;
    internal event Action<EngineHostRequest>? ClaudeHostRequest;

    internal EngineClient(TimeSpan? commandTimeout = null) => this.commandTimeout = commandTimeout ?? TimeSpan.FromSeconds(15);

    internal async Task StartAsync(string executable, bool demo, string language, object? configuration = null, bool referenceFixture = false, bool claudeWebFixture = false, bool readOnlyDiagnostics = false, Guid? notificationQa = null, string? claudeRuntimeRoot = null)
    {
        if (process != null) throw new InvalidOperationException("Engine already started.");
        callbacks = SynchronizationContext.Current;
        if (referenceFixture && !demo) throw new ArgumentException("Reference fixtures require demo mode.");
        if (claudeWebFixture && (!demo || !referenceFixture)) throw new ArgumentException("Claude web fixtures require the offline reference mode.");
        if (notificationQa != null && (!demo || !referenceFixture)) throw new ArgumentException("Notification fixtures require offline reference inputs.");
        executable = Path.GetFullPath(executable);
        if (!File.Exists(executable)) throw new FileNotFoundException("PacerEngine.exe is missing.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(executable)!,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false, true)
        };
        if (demo) start.ArgumentList.Add("--demo");
        if (referenceFixture) start.ArgumentList.Add("--reference-fixture");
        if (claudeWebFixture) start.ArgumentList.Add("--claude-web-fixture");
        if (readOnlyDiagnostics) start.ArgumentList.Add("--read-only-diagnostics");
        if (notificationQa is Guid qa) { start.ArgumentList.Add("--notification-qa"); start.ArgumentList.Add(qa.ToString("D")); }
        if (!demo && !readOnlyDiagnostics && claudeRuntimeRoot != null)
        {
            start.ArgumentList.Add("--manage-claude-hooks");
            start.ArgumentList.Add("--claude-runtime-root"); start.ArgumentList.Add(Path.GetFullPath(claudeRuntimeRoot));
        }
        start.ArgumentList.Add("--language"); start.ArgumentList.Add(language);
        job = new OwnedJob();
        try
        {
            process = Process.Start(start) ?? throw new IOException("Could not start PacerEngine.");
            // The engine starts no collectors before the initialize handshake.
            job.Attach(process);
            reading = ReadAsync(process.StandardOutput.BaseStream);
            drainingErrors = DrainErrorsAsync(process.StandardError.BaseStream);
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(10), lifetime.Token);
            await SendAsync("initialize", configuration);
            initialized = true;
        }
        catch { await DisposeAsync(); throw; }
    }

    internal async Task SendAsync(string method, object? parameters = null)
        => _ = await RequestAsync(method, parameters);

    internal async Task SetWebHostAsync(bool available)
    {
        bool previous = acceptsWebHostMessages; acceptsWebHostMessages = true;
        try { await SendAsync("setDeepSeekWebHost", new { webAvailable = available }); }
        catch { acceptsWebHostMessages = previous; throw; }
    }

    internal async Task<T> QueryAsync<T>(string method, object? parameters = null, TimeSpan? timeout = null, CancellationToken cancellation = default)
    {
        JsonElement? value = await RequestAsync(method, parameters, timeout, cancellation).ConfigureAwait(false);
        if (value == null) throw new InvalidDataException("The engine returned no query result.");
        try { return value.Value.Deserialize<T>(Json) ?? throw new InvalidDataException("The engine returned an empty query result."); }
        catch (JsonException error) { throw new InvalidDataException("The engine returned an incompatible query result.", error); }
    }
    internal async Task SetClaudeWebHostAsync(bool available)
    {
        bool previous = acceptsClaudeHostMessages; acceptsClaudeHostMessages = true;
        try { await SendAsync("setClaudeWebHost", new { webAvailable = available }); }
        catch { acceptsClaudeHostMessages = previous; throw; }
    }

    private async Task<JsonElement?> RequestAsync(string method, object? parameters, TimeSpan? timeout = null, CancellationToken cancellation = default)
    {
        if (!initialized && method != "initialize" && method != "shutdown") throw new IOException("Engine is initializing.");
        if (process is not { HasExited: false } child) throw new IOException("Engine is not running.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellation);
        deadline.CancelAfter(timeout ?? commandTimeout);
        string id = Interlocked.Increment(ref request).ToString(System.Globalization.CultureInfo.InvariantCulture);
        byte[] frame = JsonSerializer.SerializeToUtf8Bytes(new
        {
            protocolVersion = Version, id, method, @params = parameters
        });
        if (frame.Length > 64 * 1024) throw new EngineCommandException("commandLimit");
        var response = new TaskCompletionSource<JsonElement?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(id, response)) throw new InvalidOperationException("Duplicate engine command.");
        try
        {
            await writing.WaitAsync(deadline.Token).ConfigureAwait(false);
            try
            {
                await child.StandardInput.BaseStream.WriteAsync(frame, deadline.Token).ConfigureAwait(false);
                await child.StandardInput.BaseStream.WriteAsync(new byte[] { 10 }, deadline.Token).ConfigureAwait(false);
                await child.StandardInput.BaseStream.FlushAsync(deadline.Token).ConfigureAwait(false);
            }
            finally { writing.Release(); }
            return await response.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!lifetime.IsCancellationRequested && !cancellation.IsCancellationRequested) { throw new IOException("The engine did not acknowledge the command within its deadline."); }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task ReadAsync(Stream stream)
    {
        byte[] buffer = new byte[8192];
        using var line = new MemoryStream();
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                int count = await stream.ReadAsync(buffer, lifetime.Token).ConfigureAwait(false);
                if (count == 0) break;
                for (int i = 0; i < count; i++)
                {
                    if (buffer[i] == 10)
                    {
                        if (line.Length != 0) Receive(line.ToArray());
                        line.SetLength(0);
                    }
                    else
                    {
                        if (line.Length >= MaximumFrame) throw new InvalidDataException("Engine frame limit exceeded.");
                        line.WriteByte(buffer[i]);
                    }
                }
            }
            if (line.Length != 0) throw new InvalidDataException("Truncated engine frame.");
            if (!lifetime.IsCancellationRequested && !disposing) Publish(() => Status?.Invoke("engineStopped"));
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
        {
            ready.TrySetException(new IOException("Engine protocol failed."));
            if (!disposing) Publish(() => Status?.Invoke("engineProtocolFailed"));
        }
        finally
        {
            connectionClosed = true;
            var error = new IOException("Engine connection closed.");
            ready.TrySetException(error);
            foreach (var item in pending.Values) item.TrySetException(error);
            initialized = false;
            // An invalid or closed protocol cannot leave collectors running.
            if (!disposing) job?.Dispose();
        }
    }

    private void Receive(byte[] frame)
    {
        using JsonDocument document = JsonDocument.Parse(frame);
        JsonElement root = document.RootElement;
        if (root.GetProperty("protocolVersion").GetInt32() != Version) throw new InvalidDataException("Protocol version mismatch.");
        switch (root.GetProperty("type").GetString())
        {
            case "hostRequest":
            case "hostCancel":
                string? operation = root.GetProperty("operation").GetString();
                if (!initialized || !(operation == "deepseek.balance" && acceptsWebHostMessages || operation == "claude.session" && acceptsClaudeHostMessages))
                    throw new InvalidDataException("Unexpected browser request.");
                string? hostID = root.GetProperty("requestID").GetString(), context = root.GetProperty("context").GetString();
                if (hostID is not { Length: 36 } || context is not { Length: 36 } || !Guid.TryParseExact(hostID, "D", out _) || !Guid.TryParseExact(context, "D", out _))
                    throw new InvalidDataException("Invalid browser request scope.");
                var hostRequest = new EngineHostRequest(hostID!, context!, root.GetProperty("type").GetString() == "hostCancel");
                if (operation == "claude.session") Publish(() => ClaudeHostRequest?.Invoke(hostRequest)); else Publish(() => HostRequest?.Invoke(hostRequest));
                break;
            case "hello":
                if (root.GetProperty("engine").GetString() != "PacerEngine") throw new InvalidDataException("Unexpected engine.");
                ready.TrySetResult();
                break;
            case "snapshot":
                if (!ready.Task.IsCompletedSuccessfully) throw new InvalidDataException("Snapshot before handshake.");
                var snapshot = JsonSerializer.Deserialize<EngineSnapshot>(frame, Json) ?? throw new InvalidDataException("Empty snapshot.");
                if (snapshot.Tasks == null || snapshot.Requests == null || snapshot.Sources == null || snapshot.Quota == null || snapshot.Notices == null)
                    throw new InvalidDataException("Incomplete snapshot.");
                if (snapshot.Sequence <= sequence) throw new InvalidDataException("Out-of-order snapshot.");
                sequence = snapshot.Sequence;
                Volatile.Write(ref latestSnapshot, snapshot);
                Publish(() => Snapshot?.Invoke(snapshot));
                break;
            case "result":
                if (root.GetProperty("id").GetString() is not string resultId || !root.GetProperty("ok").GetBoolean())
                    throw new InvalidDataException("Invalid command result.");
                if (pending.TryGetValue(resultId, out var response))
                    response.TrySetResult(root.TryGetProperty("value", out var value) ? value.Clone() : null);
                break;
            case "error":
                string code = root.GetProperty("code").GetString() ?? "engineError";
                if (code.Length > 64 || code.IndexOfAny(new[] { '\r', '\n', '\0' }) >= 0)
                    throw new InvalidDataException("Invalid engine error code.");
                if (root.TryGetProperty("id", out var errorId) && errorId.GetString() is string commandId
                    && pending.TryGetValue(commandId, out var failure)) failure.TrySetException(new EngineCommandException(code));
                else Publish(() => Status?.Invoke("engineError"));
                break;
            default: throw new InvalidDataException("Unknown engine message.");
        }
    }

    private async Task DrainErrorsAsync(Stream stream)
    {
        byte[] buffer = new byte[4096];
        try { while (await stream.ReadAsync(buffer, lifetime.Token).ConfigureAwait(false) != 0) { } }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (IOException) { }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposing) return;
        disposing = true;
        if (!lifetime.IsCancellationRequested && process is { HasExited: false } child)
        {
            try
            {
                await SendAsync("shutdown"); child.StandardInput.Close();
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
            }
            catch (Exception ex) when (ex is IOException or TimeoutException or InvalidOperationException) { }
        }
        lifetime.Cancel();
        job?.Dispose(); job = null;
        if (process is { HasExited: false } remaining) remaining.Kill();
        if (reading != null) { try { await reading; } catch (IOException) { } }
        if (drainingErrors != null) { try { await drainingErrors; } catch (IOException) { } }
        process?.Dispose(); process = null;
    }
}

internal sealed class EngineCommandException : IOException
{
    internal string Code { get; }
    internal EngineCommandException(string code) : base("The engine rejected the command.") => Code = code;
}
