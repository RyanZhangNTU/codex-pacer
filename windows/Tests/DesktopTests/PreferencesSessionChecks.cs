using CodexPacer.Windows;
using System.Text.Json;

internal static class PreferencesSessionChecks
{
    internal static async Task Run()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var saved = new List<DesktopPreferences>();
        int commands = 0, changes = 0;
        var session = new PreferencesSession(new(), async _ => { commands++; entered.TrySetResult(); await release.Task; }, value => { saved.Add(value); return true; });
        session.Changed += _ => changes++;
        Task<PreferencesApplyResult> privacy = session.ChangeAsync(p => p with { HideProjects = true });
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Task<PreferencesApplyResult> language = session.ChangeAsync(p => p with { Language = "zh-Hans", ShowAppButtons = false, DisplayMode = "notch", ExpandedQuotaStyle = "classic", LastSettingsPane = "appearance",
            CompactSingleTask = "count", CompactMetric = "pace", QuotaRingOuter = "claude", CodexQuotaWindow = "5h", CompactLayout = "{\"version\":9,\"leading\":[\"firstOutput\"],\"trailing\":[]}" });
        Check(saved.Count == 0 && changes == 0 && !session.Current.HideProjects, "No state is committed before the engine acknowledgement");
        release.SetResult();
        Check((await privacy) == PreferencesApplyResult.Applied && (await language) == PreferencesApplyResult.Applied,
            "Queued edits must both finish");
        Check(session.Current.HideProjects && session.Current.Language == "zh-Hans" && session.Current.ExpandedQuotaStyle == "classic" && !session.Current.ShowAppButtons && commands == 1 && saved.Count == 2 && changes == 2,
            "Queued edits must read the latest state without reconfiguring collectors for UI-only choices");
        Check(session.Current.CompactSingleTask == "count" && session.Current.CompactMetric == "pace" && session.Current.QuotaRingOuter == "claude" && session.Current.CodexQuotaWindow == "5h",
            "Compact layout and readout choices must share the same presentation-only transaction");
        Check(await session.ChangeAsync(p => p with { IslandAppearance = "classic" }) == PreferencesApplyResult.Applied
            && session.Current.IslandAppearance == "classic" && commands == 1 && changes == 3,
            "Appearance selection is saved without reconfiguring or restarting collectors");

        var configured = new List<bool>();
        var rejectedSave = new PreferencesSession(new(), value =>
        {
            configured.Add(JsonSerializer.SerializeToElement(value).GetProperty("hideProjects").GetBoolean()); return Task.CompletedTask;
        }, _ => false);
        Check(await rejectedSave.ChangeAsync(p => p with { HideProjects = true }) == PreferencesApplyResult.SaveFailed
            && configured.SequenceEqual(new[] { true, false }) && !rejectedSave.Current.HideProjects && !rejectedSave.RequiresRestart,
            "A disk failure must restore the acknowledged engine state and retain the previous preferences");

        int interruptedCalls = 0;
        var interrupted = new PreferencesSession(new(), _ => ++interruptedCalls == 1 ? Task.FromException(new IOException("lost acknowledgement")) : Task.CompletedTask, _ => true);
        Check(await interrupted.ChangeAsync(p => p with { HideProjects = true }) == PreferencesApplyResult.EngineFailed
            && interruptedCalls == 2 && !interrupted.Current.HideProjects && !interrupted.RequiresRestart,
            "A lost acknowledgement must restore the previous state before reporting failure");

        int blockedCalls = 0, blockedSaves = 0;
        var blocked = new PreferencesSession(new(), _ => { blockedCalls++; return Task.FromException(new IOException("disconnected")); }, _ => { blockedSaves++; return true; });
        Check(await blocked.ChangeAsync(p => p with { HideProjects = true }) == PreferencesApplyResult.RecoveryRequired
            && blocked.RequiresRestart && blockedCalls == 2 && blockedSaves == 0,
            "Uncertain engine state must require restart without writing new preferences");
        Check(await blocked.ChangeAsync(p => p with { Language = "zh-Hans" }) == PreferencesApplyResult.RecoveryRequired && blockedCalls == 2 && blockedSaves == 0,
            "Further edits cannot bypass required recovery");

        int invalidCalls = 0;
        var invalid = new PreferencesSession(new(), _ => { invalidCalls++; return Task.CompletedTask; }, _ => { invalidCalls++; return true; });
        Check(await invalid.ChangeAsync(p => p with { RetentionMinutes = -1 }) == PreferencesApplyResult.Invalid && invalidCalls == 0,
            "Invalid edits cannot touch the engine or the preference file");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
