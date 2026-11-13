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
    private EngineCrashLog? crashLog;
    private string? crashIdentifier;
    private readonly Stopwatch running = new();
    // The engine's error text can quote paths, so none of it is kept. Each line
    // is read only far enough to see whether Swift named the source line it
    // stopped at, and the crash report gets that location alone.
    private readonly byte[] errorLine = new byte[256];
    private int errorLineLength;
    private string? swiftStop;
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

    internal async Task StartAsync(string executable, bool demo, string language, object? configuration = null, bool referenceFixture = false, bool claudeWebFixture = false, bool readOnlyDiagnostics = false, Guid? notificationQa = null, string? claudeRuntimeRoot = null, string? codexProgressRuntimeRoot = null, EngineCrashLog? crashLog = null)
    {
        if (process != null) throw new InvalidOperationException("Engine already started.");
        this.crashLog = crashLog;
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
        if (!demo && !readOnlyDiagnostics && codexProgressRuntimeRoot != null)
        {
            start.ArgumentList.Add("--codex-progress-runtime-root");
            start.ArgumentList.Add(Path.GetFullPath(codexProgressRuntimeRoot));
        }
        if (crashLog != null)
        {
            crashIdentifier = EngineCrashLog.NewIdentifier(DateTimeOffset.UtcNow);
            start.ArgumentList.Add("--crash-log-directory"); start.ArgumentList.Add(crashLog.Directory);
            start.ArgumentList.Add("--crash-log-id"); start.ArgumentList.Add(crashIdentifier);
            start.ArgumentList.Add("--app-version"); start.ArgumentList.Add(crashLog.Version);
        }
        start.ArgumentList.Add("--language"); start.ArgumentList.Add(language);
        // Swift Foundation on Windows reports GMT as the current zone, so local
        // days (Codex log folders, daily budgets, reset times) need the user's zone.
        if (!referenceFixture)
        {
            var zone = EngineTimeZone.Argument(TimeZoneInfo.Local, DateTimeOffset.UtcNow);
            start.ArgumentList.Add(zone.Flag); start.ArgumentList.Add(zone.Value);
        }
        job = new OwnedJob();
        try
        {
            process = Process.Start(start) ?? throw new IOException("Could not start PacerEngine.");
            running.Start();
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
                // Copy each run up to a newline at once; a frame is parsed from the
                // line buffer itself, which is reused only after Receive returns.
                for (int offset = 0; offset < count;)
                {
                    int newline = Array.IndexOf(buffer, (byte)10, offset, count - offset);
                    int length = (newline < 0 ? count : newline) - offset;
                    if (line.Length + length > MaximumFrame) throw new InvalidDataException("Engine frame limit exceeded.");
                    line.Write(buffer, offset, length);
                    if (newline < 0) break;
                    if (line.Length != 0) Receive(new ReadOnlyMemory<byte>(line.GetBuffer(), 0, (int)line.Length));
                    line.SetLength(0);
                    offset = newline + 1;
                }
            }
            // The engine's output ended on its own. Its exit is recorded first, whatever its last
            // frame looks like: an engine that stops while it writes leaves half a frame.
            bool stopped = !lifetime.IsCancellationRequested && !disposing;
            if (stopped) await CompleteCrashReportAsync().ConfigureAwait(false);
            if (line.Length != 0) throw new InvalidDataException("Truncated engine frame.");
            if (stopped) Publish(() => Status?.Invoke("engineStopped"));
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

    /// The envelope's version and type, read without building a document: a
    /// snapshot is most of the traffic and is deserialized from the frame once.
    private static (int? Version, string? Type) Envelope(ReadOnlySpan<byte> frame)
    {
        var reader = new Utf8JsonReader(frame);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) throw new InvalidDataException("Invalid engine frame.");
        int? version = null; string? type = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName && (version == null || type == null))
        {
            if (reader.ValueTextEquals("protocolVersion"u8)) { reader.Read(); version = reader.GetInt32(); }
            else if (reader.ValueTextEquals("type"u8)) { reader.Read(); type = reader.GetString(); }
            else reader.Skip();
        }
        return (version, type);
    }

    private void Receive(ReadOnlyMemory<byte> frame)
    {
        if (Envelope(frame.Span) is (int version, "snapshot"))
        {
            if (version != Version) throw new InvalidDataException("Protocol version mismatch.");
            ReceiveSnapshot(frame.Span);
            return;
        }
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
                ReceiveSnapshot(frame.Span);
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

    /// Every snapshot reaches every subscriber in order: notifications read
    /// each one's notices. Renderers coalesce on their own side.
    private void ReceiveSnapshot(ReadOnlySpan<byte> frame)
    {
        if (!ready.Task.IsCompletedSuccessfully) throw new InvalidDataException("Snapshot before handshake.");
        var snapshot = JsonSerializer.Deserialize<EngineSnapshot>(frame, Json) ?? throw new InvalidDataException("Empty snapshot.");
        if (snapshot.Tasks == null || snapshot.Requests == null || snapshot.Sources == null || snapshot.Quota == null || snapshot.Notices == null)
            throw new InvalidDataException("Incomplete snapshot.");
        if (snapshot.Sequence <= sequence) throw new InvalidDataException("Out-of-order snapshot.");
        sequence = snapshot.Sequence;
        Volatile.Write(ref latestSnapshot, snapshot);
        Publish(() => Snapshot?.Invoke(snapshot));
    }

    private async Task DrainErrorsAsync(Stream stream)
    {
        byte[] buffer = new byte[4096];
        try
        {
            int count;
            while ((count = await stream.ReadAsync(buffer, lifetime.Token).ConfigureAwait(false)) != 0)
                for (int i = 0; i < count; i++)
                {
                    if (buffer[i] == 10) { KeepSwiftStop(); errorLineLength = 0; }
                    // A location fits the start of a line; the rest of a long line is passed over.
                    else if (errorLineLength < errorLine.Length) errorLine[errorLineLength++] = buffer[i];
                }
            KeepSwiftStop();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (IOException) { }
    }

    private void KeepSwiftStop()
    {
        if (EngineCrashLog.SwiftStop(Encoding.ASCII.GetString(errorLine, 0, errorLineLength)) is { } stop) Volatile.Write(ref swiftStop, stop);
    }

    /// <summary>
    /// Runs after the engine's output ended on its own. Its pipes close when the
    /// process ends, so the exit code is available at once; this start's report
    /// gets that code and the source line Swift named, if it named one.
    /// </summary>
    private async Task CompleteCrashReportAsync()
    {
        if (crashLog is not { } log || crashIdentifier is not { } identifier || process is not { } child) return;
        try
        {
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            // The exit is recorded even when the error text has not ended yet.
            if (drainingErrors is { } draining) await Task.WhenAny(draining, Task.Delay(TimeSpan.FromSeconds(1))).ConfigureAwait(false);
            log.Complete(identifier, child.Id, child.ExitCode, running.Elapsed, Volatile.Read(ref swiftStop), DateTimeOffset.UtcNow);
        }
        catch (Exception error) when (error is TimeoutException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
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
