#nullable enable

// An isolated helper process: it holds one synthetic file open with the requested
// access until it is stopped, and exits at once without arguments. It never opens
// Codex, its data or any endpoint.
if (args.Length != 3) return 2;
string mode = args[0], file = args[1], ready = args[2];
if (mode is not ("file-read" or "file-write" or "file-append")) return 2;
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
try
{
    using var handle = new FileStream(file, mode == "file-append" ? FileMode.Append : FileMode.Open,
        mode == "file-read" ? FileAccess.Read : FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
    File.WriteAllText(ready, "ready");
    await Task.Delay(Timeout.InfiniteTimeSpan, deadline.Token);
}
catch (Exception error) when (error is OperationCanceledException or IOException) { }
return 0;
