using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record UpdateInstallPlan(int SchemaVersion, int Parent, long ParentStarted, string PublicKey, string? SignerSHA256,
    Guid? TestScope, WindowsUpdatePackage Package, string SHA256);
internal sealed record UpdateInstallResult(int SchemaVersion, bool Success, string Build, string Notes);
internal sealed record PreparedWindowsUpdate(string Helper, string Plan, WindowsInstallationIdentity Identity);
internal sealed class UpdateInstallerStillRunning : Exception;

internal static class UpdateInstallFlow
{
    // The parent exit is a hard boundary: collectors, descendants, windows and
    // the instance lock must be gone before the installer is allowed to start.
    internal static async Task<bool> Run(Func<Task> waitForParent, Func<Task> verify, Func<Task<int>> install,
        Action<bool> record, Action relaunch)
    {
        void Record(bool ok) { try { record(ok); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }
        try { await waitForParent(); }
        catch (Exception error) when (error is TimeoutException or OperationCanceledException or InvalidOperationException)
        { Record(false); return false; }
        bool success;
        try { await verify(); success = await install() == 0; }
        catch (UpdateInstallerStillRunning) { Record(false); return false; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidDataException or OperationCanceledException or TimeoutException or CryptographicException)
        { success = false; }
        Record(success); relaunch(); return success;
    }
}

internal static class UpdateHandoff
{
    // JSON escaping can expand the bounded 128 KiB Unicode notes by 6x.
    private const int MetadataLimit = 1024 * 1024;
    internal static PreparedWindowsUpdate Prepare(string downloaded, UpdateFeedProxy proxy, WindowsUpdateChannel channel,
        WindowsInstallationIdentity identity, string maintenance)
    {
        byte[] bytes = UpdateFiles.Read(downloaded, UpdateCatalog.PackageLimit);
        var item = proxy.ValidateDownloaded(bytes);
        if (channel.TestScope != identity.QaScope)
            throw new InvalidDataException("The installer publisher is not trusted.");
        string directory = Path.Combine(identity.DataRoot, "Updates", Guid.NewGuid().ToString("N"));
        UpdateFiles.Check(directory); Directory.CreateDirectory(directory); UpdateFiles.Check(directory);
        UpdateFiles.Write(Path.Combine(directory, "setup.exe"), bytes);
        CheckInstallerIdentity(Path.Combine(directory, "setup.exe"), identity, item.Build);
        if (channel.TestScope == null && !UpdateAuthenticode.Verify(Path.Combine(directory, "setup.exe"), channel.SignerSHA256!))
            throw new InvalidDataException("The installer publisher is not trusted.");
        UpdateFiles.Write(Path.Combine(directory, "PacerUpdate.exe"), UpdateFiles.Read(maintenance, 128 * 1024 * 1024));
        using var parent = Process.GetCurrentProcess();
        var plan = new UpdateInstallPlan(1, parent.Id, parent.StartTime.ToUniversalTime().Ticks, channel.PublicKey, channel.SignerSHA256,
            channel.TestScope, item, Convert.ToHexStringLower(SHA256.HashData(bytes)));
        string path = Path.Combine(directory, "plan.json"); UpdateFiles.Write(path, JsonSerializer.SerializeToUtf8Bytes(plan));
        return new(Path.Combine(directory, "PacerUpdate.exe"), path, identity);
    }
    internal static void Start(PreparedWindowsUpdate prepared)
    {
        var start = new ProcessStartInfo(prepared.Helper) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(prepared.Helper)! };
        foreach (string argument in new[] { "update", prepared.Identity.Scope, prepared.Identity.Root, prepared.Plan }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("The update handoff could not start.");
    }
    internal static async Task<int> Apply(string scope, string root, string planPath)
    {
        Guid? qa = scope == "default" ? null : Guid.ParseExact(scope, "N");
        var identity = WindowsInstallationIdentity.Load(root, qa, requireContext: qa != null);
        string directory = Path.GetDirectoryName(Path.GetFullPath(planPath))!;
        string session = Path.GetFileName(directory);
        if (Path.GetFileName(planPath) != "plan.json" || !Guid.TryParseExact(session, "N", out _) ||
            !string.Equals(Path.GetDirectoryName(directory), Path.Combine(identity.DataRoot, "Updates"), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The update handoff is outside its owned directory.");
        var plan = JsonSerializer.Deserialize<UpdateInstallPlan>(UpdateFiles.Read(planPath, MetadataLimit)) ?? throw new InvalidDataException();
        string architecture = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        if (plan.SchemaVersion != 1 || plan.Parent <= 0 || plan.Parent == Environment.ProcessId || plan.TestScope != qa ||
            plan.Package.Architecture != architecture || plan.Package.MinimumWindows > Environment.OSVersion.Version ||
            plan.SHA256.Length != 64) throw new InvalidDataException("The update handoff is incompatible.");
        string package = Path.Combine(directory, "setup.exe");
        FileStream? locked = null;
        bool installed = false;
        try
        {
            bool success = await UpdateInstallFlow.Run(async () =>
            {
                try
                {
                    using var parent = Process.GetProcessById(plan.Parent);
                    if (parent.StartTime.ToUniversalTime().Ticks != plan.ParentStarted) return;
                    await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
                }
                catch (ArgumentException) { }
            }, () =>
            {
                UpdateFiles.Check(package);
                locked = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (locked.Length != plan.Package.Length || locked.Length > UpdateCatalog.PackageLimit) throw new InvalidDataException();
                byte[] bytes = new byte[checked((int)locked.Length)]; locked.ReadExactly(bytes);
                if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != plan.SHA256 || !UpdateCatalog.Verify(bytes, plan.Package.Signature, plan.PublicKey) ||
                    qa == null && !UpdateAuthenticode.Verify(package, plan.SignerSHA256 ?? "")) throw new InvalidDataException("The installer failed verification.");
                CheckInstallerIdentity(package, identity, plan.Package.Build);
                return Task.CompletedTask;
            }, async () =>
            {
                var start = new ProcessStartInfo(package) { UseShellExecute = false, WorkingDirectory = directory };
                start.ArgumentList.Add("/SP-"); start.ArgumentList.Add("/NORESTART"); start.ArgumentList.Add("/DIR=" + identity.Root);
                using var process = Process.Start(start) ?? throw new IOException("The installer could not start.");
                // Do not kill an installer in the middle of replacing files.
                // A timed-out installer is left to the user, without relaunch.
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(30)); }
                catch (TimeoutException) { throw new UpdateInstallerStillRunning(); }
                return process.ExitCode;
            }, ok => { installed = ok; UpdateFiles.Write(Path.Combine(directory, "result.json"), JsonSerializer.SerializeToUtf8Bytes(
                new UpdateInstallResult(1, ok, plan.Package.Build.ToString(), plan.Package.Notes))); }, () =>
            {
                var start = new ProcessStartInfo(identity.Executable) { UseShellExecute = false, WorkingDirectory = identity.Root };
                start.ArgumentList.Add("--update-result"); start.ArgumentList.Add(session);
                if (!installed) start.ArgumentList.Add("--update-failed");
                if (qa != null)
                {
                    start.ArgumentList.Add("--demo"); start.ArgumentList.Add("--reference-fixture");
                    start.ArgumentList.Add("--activation-qa"); start.ArgumentList.Add(qa.Value.ToString("D"));
                }
                using var app = Process.Start(start) ?? throw new IOException("The application could not restart.");
            });
            return success ? 0 : 1;
        }
        finally { locked?.Dispose(); }
    }
    internal static void CheckInstallerIdentity(string path, WindowsInstallationIdentity identity, Version build)
    {
        var info = FileVersionInfo.GetVersionInfo(path);
        if (info.ProductName != identity.DisplayName || info.FileDescription != identity.DisplayName + " Setup" ||
            !Version.TryParse(info.FileVersion, out var actual) || actual != build)
            throw new InvalidDataException("The installer identity or build differs from the verified update.");
    }
    internal static UpdateInstallResult? ConsumeResult(WindowsInstallationIdentity identity, string session, WindowsUpdateState state, Version current)
    {
        if (!Guid.TryParseExact(session, "N", out _)) return null;
        string file = Path.Combine(identity.DataRoot, "Updates", session, "result.json");
        if (!File.Exists(file)) return null;
        var value = JsonSerializer.Deserialize<UpdateInstallResult>(UpdateFiles.Read(file, MetadataLimit));
        if (value?.SchemaVersion != 1 || !Version.TryParse(value.Build, out _) || value.Notes.Length > 128 * 1024) throw new InvalidDataException();
        if (value.Success && current < Version.Parse(value.Build)) value = value with { Success = false, Notes = "" };
        // Claim before presenting. A second launch cannot show this build twice.
        return state.ClaimNotes(value.Success ? value.Build : "failed-" + session) ? value : null;
    }
}
