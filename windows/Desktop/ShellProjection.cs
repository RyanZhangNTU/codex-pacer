using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

// Rendering reads completed values; it never waits for the engine.
internal static class ShellProjection
{
    internal sealed record State<T>(T? Value, bool Pending, string? Error) where T : class;
    private sealed class Entry
    {
        internal object? Value;
        internal string? Error;
        internal readonly TaskCompletionSource<object?> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    private static readonly object Gate = new();
    private static readonly Dictionary<string, Entry> Entries = new();
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static EngineClient? client;
    private static CancellationTokenSource binding = new();
    private static int generation;
    internal static TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(3);
    internal static string? LastFailure { get; private set; }
    internal static event Action<string>? Changed;
    internal static EngineClient? Client
    {
        get { lock (Gate) return client; }
        set
        {
            lock (Gate)
            {
                if (ReferenceEquals(client, value)) return;
                if (client != null) client.Status -= EngineStatus;
                binding.Cancel(); binding.Dispose(); binding = new(); generation++; Entries.Clear(); LastFailure = null;
                client = value;
                if (client != null) client.Status += EngineStatus;
            }
            Changed?.Invoke("");
        }
    }
    internal static bool HasFailure(string method)
    {
        lock (Gate) return client?.IsConnectionClosed == true || Entries.Any(item => item.Key.StartsWith(method + ":", StringComparison.Ordinal) && item.Value.Error != null);
    }
    internal static void Ready() => Changed?.Invoke("");
    private static void EngineStatus(string status)
    {
        if (status is not ("engineStopped" or "engineProtocolFailed")) return;
        lock (Gate) { generation++; binding.Cancel(); Entries.Clear(); LastFailure = "unavailable"; }
        Changed?.Invoke("");
    }
    private static Entry Get<T>(string method, JsonElement input, Func<T, bool>? valid) where T : class
    {
        string key = method + ":" + input.GetRawText();
        Entry entry; EngineClient owner; int epoch; CancellationToken token;
        lock (Gate)
        {
            if (client == null || client.IsConnectionClosed || !client.IsInitialized)
            {
                entry = new() { Error = client?.IsConnectionClosed == true ? "unavailable" : null };
                entry.Completion.TrySetResult(null); return entry;
            }
            if (Entries.TryGetValue(key, out var found)) return found;
            if (Entries.Count >= 64)
            {
                string? old = Entries.FirstOrDefault(item => item.Value.Completion.Task.IsCompleted).Key;
                if (old != null) Entries.Remove(old);
            }
            if (Entries.Count >= 64 || Entries.Values.Count(item => !item.Completion.Task.IsCompleted) >= 8)
            {
                entry = new() { Error = "busy" }; entry.Completion.TrySetResult(null); return entry;
            }
            entry = new(); Entries.Add(key, entry); owner = client; epoch = generation; token = binding.Token;
        }
        _ = Fetch(entry, owner, epoch, token, method, input, valid);
        return entry;
    }
    private static async Task Fetch<T>(Entry entry, EngineClient owner, int epoch, CancellationToken token,
        string method, JsonElement input, Func<T, bool>? valid) where T : class
    {
        object? value = null; string? error = null;
        try
        {
            T result = await owner.QueryAsync<T>(method, new { shell = input }, RequestTimeout, token).ConfigureAwait(false);
            if (valid != null && !valid(result)) throw new InvalidDataException("Incompatible presentation.");
            value = result;
        }
        catch (Exception problem) when (problem is IOException or OperationCanceledException or EngineCommandException or JsonException or ObjectDisposedException or InvalidOperationException)
        { error = owner.IsConnectionClosed || token.IsCancellationRequested ? "unavailable" : "failed"; }
        bool current;
        lock (Gate)
        {
            current = epoch == generation && ReferenceEquals(client, owner);
            if (current) { entry.Value = value; entry.Error = error; LastFailure = error; }
        }
        entry.Completion.TrySetResult(current ? value : null);
        if (current) Changed?.Invoke(method);
    }
    internal static State<T> Read<T>(string method, object request, Func<T, bool>? valid = null) where T : class
        => Read(method, request, out _, valid);
    internal static State<T> Read<T>(string method, object request, out JsonElement input, Func<T, bool>? valid = null) where T : class
    {
        input = JsonSerializer.SerializeToElement(request, Json);
        var entry = Get(method, input, valid);
        lock (Gate) return new(entry.Value as T, !entry.Completion.Task.IsCompleted, entry.Error);
    }
    internal static async Task<T> QueryAsync<T>(string method, object request, Func<T, bool>? valid = null) where T : class
    {
        var entry = Get(method, JsonSerializer.SerializeToElement(request, Json), valid);
        return await entry.Completion.Task.ConfigureAwait(false) as T ?? throw new IOException("The presentation engine did not return a usable value.");
    }
    internal static async Task WhenIdleAsync()
    {
        Task[] pending;
        lock (Gate) pending = Entries.Values.Select(item => (Task)item.Completion.Task).Where(task => !task.IsCompleted).ToArray();
        if (pending.Length > 0) await Task.WhenAll(pending).ConfigureAwait(false);
    }
}
