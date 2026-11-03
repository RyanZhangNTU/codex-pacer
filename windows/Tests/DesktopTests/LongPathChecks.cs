using CodexPacer.Windows;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

internal static class LongPathChecks
{
    internal static async Task Run(string executable)
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-long-engine-" + Guid.NewGuid().ToString("N"));
        string project = "C--synthetic-" + string.Concat(Enumerable.Repeat("project-", 26)) + "中文";
        string codex = Path.Combine(root, "codex", new string('a', 90), new string('b', 90));
        string claude = Path.Combine(root, "claude"), deepseek = Path.Combine(root, "deepseek");
        foreach (string home in new[] { codex, claude, deepseek }) Directory.CreateDirectory(home);
        Directory.CreateDirectory(Path.Combine(deepseek, "sessions"));
        try
        {
            await using var engine = new EngineClient();
            await engine.StartAsync(executable, false, "en", new { enabledProviders = new[] { "codex", "claude", "deepseek" },
                codexHome = codex, claudeHome = claude, deepseekHome = deepseek, hideProjects = true }, readOnlyDiagnostics: true);
            await engine.SendAsync("setExpanded", new { expanded = true });
            foreach (string provider in new[] { "codex", "claude", "deepseek" })
            {
                string id = Guid.NewGuid().ToString("D"), prompt = Guid.NewGuid().ToString("D"), assistant = Guid.NewGuid().ToString("D");
                string stamp = DateTimeOffset.UtcNow.ToString("O"); long milliseconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                string file = provider switch
                {
                    "codex" => Path.Combine(codex, "sessions", DateTime.Now.ToString("yyyy/MM/dd"), "rollout-" + id + ".jsonl"),
                    "claude" => Path.Combine(claude, "projects", project, id + ".jsonl"),
                    _ => Path.Combine(deepseek, "sessions", project, "session-" + id, "session.v4.jsonl.zstd")
                };
                Check(file.Length > 260, "Each provider fixture must exceed MAX_PATH");
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                string initial, ending;
                if (provider == "codex")
                {
                    initial = Row(new { type = "session_meta", timestamp = stamp, payload = new { id, source = "cli", cwd = "C:/Synthetic/Long fixture" } }) +
                        Row(new { type = "event_msg", timestamp = stamp, payload = new { type = "task_started", turn_id = prompt } });
                    ending = Row(new { type = "event_msg", timestamp = stamp, payload = new { type = "task_complete", turn_id = prompt } });
                }
                else if (provider == "claude")
                {
                    initial = Row(new { type = "user", sessionId = id, uuid = prompt, timestamp = stamp, origin = new { kind = "human" },
                        message = new { role = "user", content = "synthetic-private-prompt" } });
                    ending = Row(new { type = "assistant", sessionId = id, uuid = assistant, parentUuid = prompt, timestamp = stamp,
                        message = new { role = "assistant", content = new[] { new { type = "text", text = "synthetic-private-reply" } }, stop_reason = "end_turn" } }) +
                        Row(new { type = "system", sessionId = id, uuid = Guid.NewGuid().ToString("D"), parentUuid = assistant, timestamp = stamp,
                            subtype = "stop_hook_summary", preventedContinuation = false, hookErrors = Array.Empty<string>(), hookAdditionalContext = Array.Empty<string>() });
                }
                else
                {
                    initial = Row(new { type = "session", version = 4, id = "session-" + id, createdAt = milliseconds, cwd = "C:/Synthetic/Long fixture", delegationDepth = 0 }) +
                        Row(new { type = "turn/start", seq = 1, time = milliseconds + 1, data = new { turn = 1 } });
                    ending = Row(new { type = "turn/start", seq = 2, time = milliseconds + 2, data = new { turn = 2 } }) +
                        Row(new { type = "turn/end", seq = 3, time = milliseconds + 3, data = new { turn = 2, reason = new { kind = "completed" } } });
                }
                await File.WriteAllBytesAsync(file, provider == "deepseek" ? Frame(initial) : Encoding.UTF8.GetBytes(initial));
                await Until(() => engine.LatestSnapshot?.Tasks.Any(value => value.Provider == provider && value.SessionId == id) == true,
                    provider + " long log must be discovered and read without an explicit refresh");
                ulong before = engine.LatestSnapshot!.Sequence;
                await using (var append = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    await append.WriteAsync(provider == "deepseek" ? Frame(ending) : Encoding.UTF8.GetBytes(ending));
                await Until(() => engine.LatestSnapshot?.Tasks.Any(value => value.Provider == provider && value.SessionId == id && value.Phase == "completed" && value.Unread) == true,
                    provider + " append must wake its actual reader and preserve unread completion");
                Check(engine.LatestSnapshot!.Sequence > before, "A directory notification must publish the appended ending");
                string projected = JsonSerializer.Serialize(engine.LatestSnapshot);
                Check(!projected.Contains("synthetic-private-", StringComparison.Ordinal), "Long-path handling must not retain transcript content");
            }
        }
        finally
        {
            string target = Path.GetFullPath(root), parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("pacer-long-engine-", StringComparison.Ordinal) || new DirectoryInfo(target).LinkTarget != null)
                throw new InvalidOperationException("Unexpected long-path fixture root");
            Directory.Delete(target, true);
        }
    }
    private static string Row(object value) => JsonSerializer.Serialize(value) + "\n";
    // A valid single-segment Zstandard frame with one raw block.
    private static byte[] Frame(string text)
    {
        byte[] content = Encoding.UTF8.GetBytes(text), frame = new byte[12 + content.Length];
        frame[0] = 0x28; frame[1] = 0xb5; frame[2] = 0x2f; frame[3] = 0xfd; frame[4] = 0xa0;
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(5), (uint)content.Length);
        int block = (content.Length << 3) | 1; frame[9] = (byte)block; frame[10] = (byte)(block >> 8); frame[11] = (byte)(block >> 16);
        content.CopyTo(frame, 12); return frame;
    }
    private static async Task Until(Func<bool> predicate, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!predicate() && clock.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(25);
        Check(predicate(), message);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
