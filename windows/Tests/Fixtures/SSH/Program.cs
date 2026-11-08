using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

// No network is used. The fake remote is a disposable directory supplied by
// the test; shared commands execute there using the selected test Python.
string root = Environment.GetEnvironmentVariable("PACER_SSH_FIXTURE_ROOT") ?? throw new InvalidOperationException();
if (!Path.IsPathFullyQualified(root) || !Directory.Exists(root)) return 2;
int boundary = Array.IndexOf(args, "--");
if (boundary < 0 || !args.Contains("BatchMode=yes") || !args.Contains("UpdateHostKeys=no")) return 2;
string host = args[boundary + 1];
if (!Regex.IsMatch(host, @"\A(?:fixture@)?(?:alias-[ab]|only\.example|same\.example)\z")) return 2;
File.AppendAllText(Path.Combine(root, "calls.jsonl"), JsonSerializer.Serialize(new { pid = Environment.ProcessId, lookup = args.Contains("-G"), args = args[..(boundary + 2)] }) + "\n");
if (args.Contains("-G"))
{
    int portIndex = Array.IndexOf(args, "-p");
    string port = portIndex >= 0 ? args[portIndex + 1] : "22";
    Console.Write("hostname " + (host.Contains("only") ? "only.example" : "same.example") + "\nuser fixture\nport " + port + "\n");
    return 0;
}
if (File.Exists(Path.Combine(root, "disconnect"))) return 255;
Stream input = Console.OpenStandardInput();
var digits = new StringBuilder();
while (true)
{
    int value = input.ReadByte();
    if (value == 10) break;
    if (value is < 48 or > 57 || digits.Length >= 7) return 2;
    digits.Append((char)value);
}
if (!int.TryParse(digits.ToString(), out int length) || length is <= 0 or > 1048576) return 2;
byte[] bytes = new byte[length]; input.ReadExactly(bytes);
string command = Encoding.UTF8.GetString(bytes);
string replay = Path.Combine(root, "frames.jsonl");
if (File.Exists(replay))
{
    await Console.OpenStandardOutput().WriteAsync(File.ReadAllBytes(replay));
    await input.CopyToAsync(Stream.Null); return 0;
}
var match = Regex.Match(command, "\\Apython3 -u -c 'import base64;exec\\(base64\\.b64decode\\(\"([A-Za-z0-9+/=]+)\"\\)(?:\\.decode\\([^)]*\\))?\\)'(?: (.*))?\\z");
if (!match.Success) return 2;
string code = Encoding.UTF8.GetString(Convert.FromBase64String(match.Groups[1].Value));
string[] tail = match.Groups[2].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
if (tail.Length == 0 || tail.Any(value => !Regex.IsMatch(value, @"\A[A-Za-z0-9+/=._-]+\z"))) return 2;
string remoteHome = Encoding.UTF8.GetString(Convert.FromBase64String(tail[0]));
bool setup = remoteHome.StartsWith('{');
if (setup)
{
    using var request = JsonDocument.Parse(remoteHome);
    if (request.RootElement.GetProperty("home").GetString() != "~/.claude" || !request.RootElement.TryGetProperty("hook", out _)) return 2;
    string mode = Path.Combine(root, "setup-mode");
    if (File.Exists(mode) && File.ReadAllText(mode) == "hang")
    { await input.CopyToAsync(Stream.Null); File.WriteAllText(Path.Combine(root, "eof"), "true"); await Task.Delay(30000); return 0; }
}
else if (!Path.GetFullPath(remoteHome).StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return 2;
string source = Path.Combine(root, "command-" + Guid.NewGuid().ToString("N") + ".py");
// Supply POSIX resource/pipe readiness facts to the unchanged shared helper.
// These shims exist only in this synthetic executable, never in the app.
string shim = """
import os,sys,time,types,select,ctypes
sys.stdout.reconfigure(newline='\n')
os.getuid=lambda:0
os.O_NOFOLLOW=getattr(os,'O_NOFOLLOW',0)
os.O_CLOEXEC=getattr(os,'O_CLOEXEC',0)
os.fchmod=getattr(os,'fchmod',lambda fd,mode:None)
sys.modules['resource']=types.SimpleNamespace(RUSAGE_SELF=0,getrusage=lambda _:types.SimpleNamespace(ru_utime=0,ru_stime=0))
original_select=select.select
def fixture_select(readers,writers,errors,timeout=None):
    if 0 not in readers:return original_select(readers,writers,errors,timeout)
    until=time.monotonic()+(timeout or 0)
    while True:
        count=ctypes.c_ulong()
        handle=ctypes.windll.kernel32.GetStdHandle(-10)
        ok=ctypes.windll.kernel32.PeekNamedPipe(ctypes.c_void_p(handle),None,0,None,ctypes.byref(count),None)
        ready=[0] if not ok or count.value else []
        rest=[item for item in readers if item!=0]
        if rest:ready+=original_select(rest,[],[],0)[0]
        if ready or time.monotonic()>=until:return ready,[],[]
        time.sleep(min(.01,max(0,until-time.monotonic())))
select.select=fixture_select

""";
// A real remote runs the command in its own shell, where one argument can be
// 128 KiB. This Windows stand-in hands the arguments over in a file instead,
// so CreateProcess's 32,767-character command line does not cap the payload.
string argumentsFile = Path.Combine(root, "arguments-" + Guid.NewGuid().ToString("N") + ".txt");
File.WriteAllText(argumentsFile, string.Join('\n', tail), new UTF8Encoding(false));
string readArguments = "sys.argv[1:]=open(" + JsonSerializer.Serialize(argumentsFile) + ",encoding='utf-8').read().split('\\n')\n";
File.WriteAllText(source, shim + readArguments + "\n" + code, new UTF8Encoding(false));
try
{
    var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("PACER_TEST_PYTHON")!)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root };
    if (setup)
    {
        start.Environment["USERPROFILE"] = root; start.Environment["HOME"] = root;
        foreach (string key in start.Environment.Keys.Where(key => key.StartsWith("OTEL_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("CLAUDE_", StringComparison.OrdinalIgnoreCase)).ToArray()) start.Environment.Remove(key);
    }
    foreach (string argument in new[] { "-S", "-u", source }) start.ArgumentList.Add(argument);
    using var process = Process.Start(start)!;
    _ = Task.Run(async () => { try { await input.CopyToAsync(process.StandardInput.BaseStream); process.StandardInput.Close(); } catch (IOException) { } });
    Task output = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
    Task error = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
    await process.WaitForExitAsync(); await Task.WhenAll(output, error); return process.ExitCode;
}
finally { File.Delete(source); File.Delete(argumentsFile); }
