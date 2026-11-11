using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record UpdateInstallPlan(int SchemaVersion, int Parent, long ParentStarted, string PublicKey, string? SignerSHA256,
    Guid? TestScope, WindowsUpdatePackage Package, string SHA256, string Language = "en");
// Written by the previous build's helper and read by the new app: fields are
// only ever added, as optional values.
internal sealed record UpdateInstallResult(int SchemaVersion, bool Success, string Build, string Notes, bool Incremental = false);
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
    /// The build whose patch failed here; that build is then installed in full.
    internal const string PatchFailedKey = "PacerPatchFailedBuild";
    // JSON escaping can expand the bounded 128 KiB Unicode notes by 6x.
    private const int MetadataLimit = 1024 * 1024;
    internal static PreparedWindowsUpdate Prepare(VerifiedDownload download, WindowsUpdateChannel channel,
        WindowsInstallationIdentity identity, string maintenance, string language)
    {
        if (channel.TestScope != identity.QaScope)
            throw new InvalidDataException("The installer publisher is not trusted.");
        string directory = Path.GetFullPath(download.Directory), copied = Path.Combine(directory, UpdateFeedClient.InstallerName);
        if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out _) || !string.Equals(Path.GetFullPath(download.Installer), copied, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetDirectoryName(directory), Path.GetFullPath(UpdateSessions.Root(identity.DataRoot)), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The update download is outside its owned directory.");
        var item = download.Package;
        CheckInstallerIdentity(copied, identity, item.Build);
        VerifyPackage(copied, UpdateFiles.Read(copied, UpdateCatalog.PackageLimit), download.SHA256, item.Signature, channel.PublicKey, channel.SignerSHA256);
        UpdateFiles.Write(Path.Combine(directory, "PacerUpdate.exe"), UpdateFiles.Read(maintenance, 128 * 1024 * 1024));
        using var parent = Process.GetCurrentProcess();
        var plan = new UpdateInstallPlan(1, parent.Id, parent.StartTime.ToUniversalTime().Ticks, channel.PublicKey, channel.SignerSHA256,
            channel.TestScope, item, download.SHA256, language);
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
        string package = Path.Combine(directory, UpdateFeedClient.InstallerName), log = Path.Combine(directory, UpdateSessions.InstallLog);
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
                VerifyPackage(package, bytes, plan.SHA256, plan.Package.Signature, plan.PublicKey, plan.SignerSHA256);
                CheckInstallerIdentity(package, identity, plan.Package.Build);
                return Task.CompletedTask;
            }, async () =>
            {
                var start = new ProcessStartInfo(package) { UseShellExecute = false, WorkingDirectory = directory };
                foreach (string argument in InstallerArguments(identity.Root, log, plan.Language)) start.ArgumentList.Add(argument);
                using var process = Process.Start(start) ?? throw new IOException("The installer could not start.");
                // Do not kill an installer in the middle of replacing files.
                // A timed-out installer is left to the user, without relaunch.
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(30)); }
                catch (TimeoutException) { throw new UpdateInstallerStillRunning(); }
                int code = process.ExitCode;
                locked?.Dispose(); locked = null;
                await Finished(directory, log, package);
                return code;
            }, ok => { installed = ok; UpdateFiles.Write(Path.Combine(directory, "result.json"), JsonSerializer.SerializeToUtf8Bytes(
                new UpdateInstallResult(1, ok, plan.Package.Build.ToString(), plan.Package.Notes, plan.Package.Incremental))); }, () =>
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
    // The person already chose Install in the update offer: show progress
    // only, in the app's language, without wizard pages or a confirmation,
    // like Sparkle on the Mac. The log stays with the update for diagnosis.
    internal static string[] InstallerArguments(string root, string log, string language) =>
        ["/SP-", "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LANG=" + InstallerLanguage(language), "/LOG=" + log, "/DIR=" + root];
    internal static string InstallerLanguage(string language) => language == "zh-Hans" ? "chinesesimplified" : "english";
    // Setup's loader can exit before its worker releases the log. The
    // installer itself is no longer needed once it has run.
    private static async Task Finished(string directory, string log, string package)
    {
        for (int attempt = 0; attempt < 20 && File.Exists(log); attempt++)
        {
            try { using (new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.None)) { } break; }
            catch (IOException) { await Task.Delay(500); }
        }
        try { UpdateSessions.PreserveLog(directory); } catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { }
        try { File.Delete(package); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    // Both handoff boundaries always verify content. A publisher certificate
    // is an additional requirement only when the channel explicitly pins one.
    internal static void VerifyPackage(string path, byte[] bytes, string digest, string signature, string key, string? signer,
        Func<string, string, bool>? authenticode = null)
    {
        if (bytes.Length > UpdateCatalog.PackageLimit || digest.Length != 64 ||
            !string.Equals(Convert.ToHexStringLower(SHA256.HashData(bytes)), digest, StringComparison.OrdinalIgnoreCase) ||
            !UpdateCatalog.Verify(bytes, signature, key)) throw new InvalidDataException("The installer failed content verification.");
        if (signer != null && (signer.Length != 64 || !signer.All(Uri.IsHexDigit) ||
            !(authenticode ?? UpdateAuthenticode.Verify)(path, signer))) throw new InvalidDataException("The installer publisher is not trusted.");
    }
    internal static void CheckInstallerIdentity(string path, WindowsInstallationIdentity identity, Version build)
    {
        var info = FileVersionInfo.GetVersionInfo(path);
        CheckInstallerIdentity(info.ProductName, info.FileDescription, info.FileVersion, identity, build);
    }
    internal static void CheckInstallerIdentity(string? productName, string? description, string? fileVersion,
        WindowsInstallationIdentity identity, Version build)
    {
        // Inno reserves trailing space/NUL padding in its version resources.
        // Keep leading/interior characters and the exact identity checks.
        if (productName?.TrimEnd(' ', '\0') != identity.DisplayName ||
            description?.TrimEnd(' ', '\0') != identity.DisplayName + " Setup" ||
            !Version.TryParse(fileVersion?.TrimEnd(' ', '\0'), out var actual) || actual != build)
            throw new InvalidDataException("The installer identity or build differs from the verified update.");
    }
    internal static UpdateInstallResult? ConsumeResult(WindowsInstallationIdentity identity, string session, WindowsUpdateState state, Version current)
    {
        if (!Guid.TryParseExact(session, "N", out _)) return null;
        string file = Path.Combine(identity.DataRoot, "Updates", session, "result.json");
        if (!File.Exists(file)) return null;
        var value = JsonSerializer.Deserialize<UpdateInstallResult>(UpdateFiles.Read(file, MetadataLimit));
        if (value?.SchemaVersion != 1 || !Version.TryParse(value.Build, out var installed) || value.Notes.Length > 128 * 1024) throw new InvalidDataException();
        if (value.Success && current < installed) value = value with { Success = false, Notes = "" };
        if (!value.Success && value.Incremental) state.Write(PatchFailedKey, value.Build);
        if (value.Success && Version.TryParse(state.Read(PatchFailedKey), out var failed) && installed >= failed) state.Write(PatchFailedKey, null);
        // Claim before presenting. A second launch cannot show this build twice.
        return state.ClaimNotes(value.Success ? value.Build : "failed-" + session) ? value : null;
    }
}
