#nullable enable
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text.Json;

// An isolated local server; never opens Codex, its data or its endpoint.
if (args.Length != 3 && !(args.Length == 4 && args[0].StartsWith("runtime", StringComparison.Ordinal))) return 2;
string mode = args[0], endpoint = args[1], ready = args[2];
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
try
{
    if (mode is "file-read" or "file-write" or "file-append")
    {
        using var file = new FileStream(endpoint, mode == "file-append" ? FileMode.Append : FileMode.Open,
            mode == "file-read" ? FileAccess.Read : FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        File.WriteAllText(ready, "ready");
        await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token); return 0;
    }
    using var rollout = mode.StartsWith("runtime", StringComparison.Ordinal)
        ? new FileStream(args[3], FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete) : null;
    using var server = new NamedPipeServerStream(endpoint, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 4096, 4096);
    File.WriteAllText(ready, "ready");
    await server.WaitForConnectionAsync(deadline.Token);
    if (mode.StartsWith("runtime", StringComparison.Ordinal))
    {
        await Runtime(server, rollout!, mode, ready, deadline.Token);
        server.Dispose(); // Keep the verified file writer alive after EOF.
        await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token); return 0;
    }
    if (mode == "close") { await server.ReadExactlyAsync(new byte[1], deadline.Token); return 0; }
    if (mode == "silent") { await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token); return 0; }
    if (mode == "partial-header")
    {
        await server.WriteAsync(new byte[] { 128 }, deadline.Token);
        await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token); return 0;
    }
    if (mode == "frame")
    {
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new { type = "response", method = "initialize", resultType = "success",
            result = new { clientId = "00000000-0000-4000-8000-000000000010" }, transcript = "PRIVATE-TRANSCRIPT-" + new string('x', 100_000) });
        byte[] length = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)payload.Length);
        foreach (byte value in length) await server.WriteAsync(new[] { value }, deadline.Token);
        for (int index = 0; index < payload.Length; index += 127)
            await server.WriteAsync(payload.AsMemory(index, Math.Min(127, payload.Length - index)), deadline.Token);
    }
    if (mode == "large-frame")
    {
        object Wire(object change) => new { type = "broadcast", method = "thread-stream-state-changed", version = 11,
            sourceClientId = "019a0000-0000-7000-8000-000000000020", @params = new { hostId = "local", conversationId = "019a0000-0000-7000-8000-000000000001", change } };
        async Task Send(object value)
        {
            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(value), length = new byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)payload.Length);
            await server.WriteAsync(length, deadline.Token);
            for (int offset = 0; offset < payload.Length; offset += 64 * 1024)
                await server.WriteAsync(payload.AsMemory(offset, Math.Min(64 * 1024, payload.Length - offset)), deadline.Token);
        }
        await Send(Wire(new { type = "snapshot", revision = 0, conversationState = new {
            title = "Synthetic task", resumeState = "resumed", threadRuntimeStatus = new { type = "active", activeFlags = Array.Empty<string>() },
            latestTokenUsageInfo = new { total = new { outputTokens = 9000 } }, unrelatedHistory = "PRIVATE-HISTORY-" + new string('x', 20 * 1024 * 1024),
            turns = new[] {
                new { turnId = "old", status = "completed", turnStartedAtMs = 500, items = new object[] { new { id = "old-message", type = "userMessage", text = "PRIVATE-OLD" } } },
                new { turnId = "current", status = "inProgress", turnStartedAtMs = 1000, items = new object[] { new { id = "tool", type = "commandExecution", status = "inProgress", command = "PRIVATE-COMMAND" } } }
            }
        } }));
        await Send(Wire(new { type = "patches", baseRevision = 0, revision = 1, patches = new object[] {
            new { op = "add", path = new object[] { "turns", 1, "items", 1 }, value = new { id = "answer", type = "agentMessage", text = "PRIVATE-RESPONSE" } },
            new { op = "replace", path = new object[] { "latestTokenUsageInfo" }, value = new { total = new { outputTokens = 9040 }, last = new { outputTokens = 40 } } },
            new { op = "replace", path = new object[] { "turns", 1, "status" }, value = "completed" },
            new { op = "replace", path = new object[] { "threadRuntimeStatus", "type" }, value = "idle" }
        } }));
    }
    var buffer = new byte[113];
    while (true)
    {
        int count = await server.ReadAsync(buffer, deadline.Token);
        if (count == 0) break;
        File.WriteAllText(ready + ".received", "received");
        if (mode == "echo")
            for (int index = 0; index < count; index += 7)
                await server.WriteAsync(buffer.AsMemory(index, Math.Min(7, count - index)), deadline.Token);
    }
}
catch (Exception error) when (error is OperationCanceledException or IOException) { }
return 0;

static async Task Runtime(NamedPipeServerStream pipe, FileStream rollout, string mode, string ready, CancellationToken token)
{
    string runtimeHost = mode == "runtime-remote" ? "remote-control:work" : "local";
    const string thread = "019a0000-0000-7000-8000-000000000001", foreign = "019a0000-0000-7000-8000-000000000002",
        child = "019a0000-0000-7000-8000-000000000003", owner = "019a0000-0000-7000-8000-000000000020";
    async Task Send(object value)
    {
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(value), length = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)payload.Length);
        await pipe.WriteAsync(length, token); await pipe.WriteAsync(payload, token);
    }
    async Task<JsonDocument?> Read()
    {
        var length = new byte[4];
        try { await pipe.ReadExactlyAsync(length, token); } catch (EndOfStreamException) { return null; }
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(length);
        if (count is 0 or > 1024 * 1024) throw new IOException("Fixture input limit");
        var data = new byte[count]; await pipe.ReadExactlyAsync(data, token);
        return JsonDocument.Parse(data);
    }
    object Wire(string id, object change) => new { type = "broadcast", method = "thread-stream-state-changed", version = 11,
        sourceClientId = owner, @params = new { hostId = runtimeHost, conversationId = id, change } };
    bool attached = false, approval = false, completed = false;
    bool repaired = false;
    int revision = 0;
    Task<JsonDocument?> read = Read();
    while (!token.IsCancellationRequested)
    {
        if (await Task.WhenAny(read, Task.Delay(20, token)) == read)
        {
            using JsonDocument? message = await read;
            if (message is null) return;
            JsonElement row = message.RootElement;
            string method = row.TryGetProperty("method", out var methodValue) ? methodValue.GetString() ?? "" : "";
            if (method == "initialize")
            {
                File.WriteAllText(ready + ".initialized", "initialized");
                if (mode != "runtime-no-init")
                {
                    await Send(new { type = "response", method = "initialize", resultType = "success",
                        result = new { clientId = "00000000-0000-4000-8000-000000000010" } });
                    foreach (string id in new[] { foreign, thread })
                        await Send(new { type = "broadcast", method = "thread-stream-following-status-requested", version = 1,
                            sourceClientId = owner, @params = new { hostId = runtimeHost, conversationId = id } });
                    if (runtimeHost != "local")
                        await Send(new { type = "broadcast", method = "thread-stream-following-status-requested", version = 1,
                            sourceClientId = owner, @params = new { hostId = "remote-control:foreign", conversationId = thread } });
                    await Send(Wire(foreign, new { type = "snapshot", revision = 0, conversationState = new { title = "FOREIGN-TITLE" } }));
                }
            }
            if (method == "thread-stream-following-changed" && row.GetProperty("params").GetProperty("following").GetBoolean())
            {
                string id = row.GetProperty("params").GetProperty("conversationId").GetString()!;
                string route = row.GetProperty("params").GetProperty("hostId").GetString()!;
                if (route != runtimeHost) File.WriteAllText(ready + ".foreign-host-follow", "foreign");
                if (id != thread) File.WriteAllText(ready + ".foreign-follow", id);
                else if (!attached)
                {
                    attached = true;
                    await Send(Wire(thread, new { type = "snapshot", revision = 0, conversationState = new {
                        title = "Synthetic runtime", cwd = "C:/synthetic", latestModel = "synthetic-model", resumeState = "resumed",
                        requests = Array.Empty<object>(), latestTokenUsageInfo = new { total = new { outputTokens = 9000 } },
                        threadRuntimeStatus = new { type = "active", activeFlags = Array.Empty<string>() }, turns = new[] {
                            new { turnId = "current", status = "inProgress", turnStartedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 5000,
                                items = new object[] {
                                    new { id = "tool", type = "commandExecution", status = "inProgress", command = "PRIVATE-COMMAND" },
                                    new { id = "child", type = "collabAgentToolCall", status = "completed", receiverThreadIds = runtimeHost == "local" ? new[] { child } : Array.Empty<string>() }
                                } }
                        }, unrelatedHistory = "PRIVATE-HISTORY" } }));
                    File.WriteAllText(ready + ".streaming", "streaming");
                }
            }
            read = Read();
        }
        if (attached && !approval && File.Exists(ready + ".approval"))
        {
            approval = true;
            await Send(Wire(thread, new { type = "patches", baseRevision = revision, revision = ++revision,
                patches = new[] { new { op = "replace", path = new object[] { "requests" }, value = new[] {
                    new { id = "permission", method = "item/commandExecution/requestApproval", @params = new { command = "PRIVATE-APPROVAL" } }
                } } } }));
        }
        if (attached && !completed && File.Exists(ready + ".complete"))
        {
            completed = true;
            await Send(Wire(thread, new { type = "patches", baseRevision = revision, revision = ++revision, patches = new object[] {
                new { op = "replace", path = new object[] { "requests" }, value = Array.Empty<object>() },
                new { op = "add", path = new object[] { "turns", 0, "items", 2 }, value = new { id = "answer", type = "agentMessage", text = "PRIVATE-RESPONSE" } },
                new { op = "replace", path = new object[] { "latestTokenUsageInfo" }, value = new { total = new { outputTokens = 9040 }, last = new { outputTokens = 40 } } },
                new { op = "replace", path = new object[] { "turns", 0, "status" }, value = "completed" },
                new { op = "replace", path = new object[] { "threadRuntimeStatus", "type" }, value = "idle" }
            } }));
            File.WriteAllText(ready + ".completion-sent", "sent");
        }
        if (File.Exists(ready + ".close")) return;
        if (!repaired && File.Exists(ready + ".repair"))
        {
            repaired = true;
            byte[] header = JsonSerializer.SerializeToUtf8Bytes(new { type = "session_meta", payload = new { id = thread, originator = "Codex Desktop", cwd = "C:/synthetic" } });
            rollout.Position = 0; rollout.SetLength(0);
            await rollout.WriteAsync(header, token); await rollout.WriteAsync(new byte[] { 10 }, token); await rollout.FlushAsync(token);
        }
    }
}
